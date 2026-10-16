// ESPDisplayAudio: a CoreAudio HAL plug-in that gives each ESPDisplay panel
// an output device in Sound settings.
//
// The driver is a thin bridge. It has no networking and no timing of its own:
// ESPDisplaySender keeps the UDP transport, the pacer and the drift
// correction. What macOS plays to a display's device is mixed by the HAL,
// written here into a per-device ring, and read back by the app through a
// custom property ('ESpc') that returns the frames written since its last
// read. The app says which displays exist by setting a custom property on the
// plug-in object ('ESrg'), and repeats it as a heartbeat; a display nobody has
// registered for ten seconds loses its device, so a quit or crashed app does
// not leave silent outputs behind.
//
// Custom properties are used rather than a mach service because coreaudiod
// runs the plug-in in the system launchd domain, where a service vended by an
// app in the user's session cannot be looked up. A LaunchDaemon helper would
// fix that at the cost of a second privileged install.
//
// The object model follows Apple's NullAudio sample (one plug-in object, then
// a device, an output stream, a volume and a mute control per display) and is
// written from scratch against <CoreAudio/AudioServerPlugIn.h>. The device
// runs on the host clock.

#include <CommonCrypto/CommonDigest.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "ESPDisplayAudioProtocol.h"

#pragma mark - Constants

#define kFactoryUUID "4C8C4C23-E3EB-4697-823C-EA5496D601A4"

enum {
    kMaxDevices = ESPDISP_AUDIO_MAX_DEVICES,
    kMaxClients = ESPDISP_AUDIO_MAX_CLIENTS,
    kChannels = 2,
    kBytesPerFrame = kChannels * (UInt32)sizeof(Float32),
    // One second of audio. The app polls every 10 ms and never reads more
    // than kMaxReadFrames, so the writer never laps a read in progress.
    kRingFrames = 48000,
    kMaxReadFrames = ESPDISP_AUDIO_MAX_READ_FRAMES,
    kZeroTimeStampPeriod = 16384,
    kMaxStringBytes = 256,
};

static const Float64 kSampleRate = ESPDISP_AUDIO_SAMPLE_RATE;
static const Float32 kMinimumDecibels = -96.0f;
static const UInt64 kClientTimeoutSeconds = ESPDISP_AUDIO_CLIENT_TIMEOUT_SECONDS;

#pragma mark - State

typedef struct {
    char uid[kMaxStringBytes];
    char name[kMaxStringBytes];
    UInt32 latencyFrames;
    // The secret token of the client that owns the device: the only one that
    // may read its audio.
    char owner[kMaxStringBytes];
} DeviceSpec;

typedef struct {
    bool used;
    // A per-launch secret the client sends with every registration and read.
    // It, not the process ID the HAL may or may not pass, is the client's
    // identity, so no other process can replace, withdraw or read its devices.
    char token[kMaxStringBytes];
    char id[kMaxStringBytes];
    UInt64 lastSeenHostTime;
    UInt32 deviceCount;
    DeviceSpec devices[kMaxDevices];
} Client;

typedef struct {
    // Guarded by gStateMutex. The IO entry points read everUsed, deviceID and
    // streamID without it, so those three are atomic.
    bool active;
    _Atomic bool everUsed;
    _Atomic AudioObjectID deviceID;
    _Atomic AudioObjectID streamID;
    AudioObjectID volumeID;
    AudioObjectID muteID;
    char uid[kMaxStringBytes];
    CFStringRef uidRef;
    CFStringRef nameRef;
    UInt32 latencyFrames;
    char owner[kMaxStringBytes];

    // Guarded by ioMutex.
    pthread_mutex_t ioMutex;
    UInt64 ioRunCount;
    // Whether macOS is running IO on the device, i.e. it is an output in use.
    // Read without ioMutex by whichever HAL thread reads 'ESpc'.
    _Atomic bool ioRunning;
    UInt64 anchorHostTime;
    UInt64 timestampCount;

    // Written by the IO thread, read by whichever HAL thread reads 'ESpc'.
    Float32* ring;
    _Atomic UInt64 writeHead;
    _Atomic UInt64 generation;
    _Atomic UInt32 volumeBits;
    _Atomic bool muted;

    // Guarded by readMutex: one reader cursor per device.
    pthread_mutex_t readMutex;
    UInt64 readCursor;
    UInt64 readGeneration;
} DeviceSlot;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static Float64 gHostTicksPerFrame = 0;
static Float64 gHostTicksPerSecond = 0;
static AudioObjectID gNextObjectID = 2;
static Client gClients[kMaxClients];
static DeviceSlot gSlots[kMaxDevices];
static dispatch_queue_t gQueue = NULL;
static dispatch_source_t gExpiryTimer = NULL;
static UInt64 (*gNow)(void) = mach_absolute_time;

#pragma mark - Small helpers

static Float32 VolumeScalar(const DeviceSlot* slot) {
    UInt32 bits = atomic_load_explicit(&slot->volumeBits, memory_order_relaxed);
    Float32 value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static void SetVolumeScalar(DeviceSlot* slot, Float32 value) {
    if (!(value >= 0.0f)) value = 0.0f;
    if (value > 1.0f) value = 1.0f;
    UInt32 bits;
    memcpy(&bits, &value, sizeof bits);
    atomic_store_explicit(&slot->volumeBits, bits, memory_order_relaxed);
}

// Squared, so the volume slider's steps sound about evenly spaced; the decibel
// view is the same curve, 40 log10(scalar), floored at kMinimumDecibels.
static Float32 ScalarToDecibels(Float32 scalar) {
    if (!(scalar > 0.0f)) return kMinimumDecibels;
    Float32 db = 40.0f * log10f(scalar);
    return db < kMinimumDecibels ? kMinimumDecibels : (db > 0.0f ? 0.0f : db);
}

static Float32 DecibelsToScalar(Float32 db) {
    if (!(db > kMinimumDecibels)) return 0.0f;
    if (db > 0.0f) db = 0.0f;
    return powf(10.0f, db / 40.0f);
}

static void CopyCString(char* destination, const char* source) {
    strlcpy(destination, source, kMaxStringBytes);
}

// The UID macOS sees: the registered UID plus a suffix from the owner's
// token (the first ESPDISP_AUDIO_UID_SUFFIX_BYTES bytes of its SHA-256, in
// hex). It is stable for an owner, whose token is kept across launches, and
// different for any other owner, so when a device changes hands the HAL
// cannot carry the Mac's output over to it by UID as it would for a device
// that came back.
static CFStringRef CreateDeviceUID(const char* uid, const char* owner) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(owner, (CC_LONG)strlen(owner), digest);
    char suffix[2 * ESPDISP_AUDIO_UID_SUFFIX_BYTES + 1];
    for (int index = 0; index < ESPDISP_AUDIO_UID_SUFFIX_BYTES; ++index) {
        snprintf(suffix + 2 * index, 3, "%02x", digest[index]);
    }
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("%s.%s"), uid, suffix);
}

static bool CStringFromCF(CFTypeRef value, char* destination) {
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) return false;
    if (!CFStringGetCString((CFStringRef)value, destination, kMaxStringBytes,
                            kCFStringEncodingUTF8)) {
        return false;
    }
    return destination[0] != 0;
}

static void FillFormat(AudioStreamBasicDescription* format) {
    memset(format, 0, sizeof *format);
    format->mSampleRate = kSampleRate;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
        | kAudioFormatFlagIsPacked;
    format->mBytesPerPacket = kBytesPerFrame;
    format->mFramesPerPacket = 1;
    format->mBytesPerFrame = kBytesPerFrame;
    format->mChannelsPerFrame = kChannels;
    format->mBitsPerChannel = 32;
}

typedef enum {
    kObjectNone,
    kObjectPlugIn,
    kObjectDevice,
    kObjectStream,
    kObjectVolume,
    kObjectMute,
} ObjectKind;

// Callers hold gStateMutex. Only active slots resolve, so a removed device
// stops answering property calls at once.
static ObjectKind Resolve(AudioObjectID objectID, DeviceSlot** outSlot) {
    *outSlot = NULL;
    if (objectID == kAudioObjectPlugInObject) return kObjectPlugIn;
    for (int index = 0; index < kMaxDevices; ++index) {
        DeviceSlot* slot = &gSlots[index];
        if (!slot->active) continue;
        *outSlot = slot;
        if (objectID == slot->deviceID) return kObjectDevice;
        if (objectID == slot->streamID) return kObjectStream;
        if (objectID == slot->volumeID) return kObjectVolume;
        if (objectID == slot->muteID) return kObjectMute;
    }
    *outSlot = NULL;
    return kObjectNone;
}

// The IO entry points find their device whether or not it is still listed:
// the HAL can stop IO on a device it has just been told is gone. Object IDs
// are never reused, so a stale ID cannot reach a slot given to another display.
static DeviceSlot* IOSlot(AudioObjectID deviceID) {
    for (int index = 0; index < kMaxDevices; ++index) {
        if (gSlots[index].everUsed && gSlots[index].deviceID == deviceID) {
            return &gSlots[index];
        }
    }
    return NULL;
}

#pragma mark - Device list

// Callers hold gStateMutex. Returns whether the device list changed.
static bool ApplyDesiredDevices(const DeviceSpec* desired, UInt32 count,
                                AudioObjectID* renamed, UInt32* renamedCount) {
    bool changed = false;
    *renamedCount = 0;
    for (int index = 0; index < kMaxDevices; ++index) {
        DeviceSlot* slot = &gSlots[index];
        if (!slot->active) continue;
        const DeviceSpec* match = NULL;
        for (UInt32 spec = 0; spec < count; ++spec) {
            if (strcmp(desired[spec].uid, slot->uid) == 0) match = &desired[spec];
        }
        // A device whose owner changed is retired and made again under new
        // IDs below, never handed over in place: the HAL then sees the old
        // device go, so the Mac's output cannot stay on a device whose sound
        // now goes to someone else.
        if (match == NULL || strcmp(match->owner, slot->owner) != 0) {
            slot->active = false;
            changed = true;
            continue;
        }
        CFStringRef name = CFStringCreateWithCString(
            NULL, match->name, kCFStringEncodingUTF8);
        if (name != NULL && CFStringCompare(name, slot->nameRef, 0) != kCFCompareEqualTo) {
            CFRelease(slot->nameRef);
            slot->nameRef = name;
            renamed[(*renamedCount)++] = slot->deviceID;
        } else if (name != NULL) {
            CFRelease(name);
        }
    }
    for (UInt32 spec = 0; spec < count; ++spec) {
        bool present = false;
        for (int index = 0; index < kMaxDevices; ++index) {
            if (gSlots[index].active && strcmp(gSlots[index].uid, desired[spec].uid) == 0) {
                present = true;
            }
        }
        if (present) continue;
        // A slot this display had before keeps its volume; otherwise a never
        // used slot, then any free one.
        DeviceSlot* slot = NULL;
        for (int index = 0; index < kMaxDevices && slot == NULL; ++index) {
            if (!gSlots[index].active && gSlots[index].everUsed
                && strcmp(gSlots[index].uid, desired[spec].uid) == 0) {
                slot = &gSlots[index];
            }
        }
        for (int index = 0; index < kMaxDevices && slot == NULL; ++index) {
            if (!gSlots[index].everUsed) slot = &gSlots[index];
        }
        for (int index = 0; index < kMaxDevices && slot == NULL; ++index) {
            if (!gSlots[index].active) slot = &gSlots[index];
        }
        if (slot == NULL) break;
        if (slot->ring == NULL) {
            slot->ring = calloc((size_t)kRingFrames * kChannels, sizeof(Float32));
            if (slot->ring == NULL) break;
        }
        CFStringRef uidRef = CreateDeviceUID(desired[spec].uid, desired[spec].owner);
        CFStringRef nameRef = CFStringCreateWithCString(
            NULL, desired[spec].name, kCFStringEncodingUTF8);
        if (uidRef == NULL || nameRef == NULL) {
            if (uidRef) CFRelease(uidRef);
            if (nameRef) CFRelease(nameRef);
            break;
        }
        bool sameDisplay = slot->everUsed && strcmp(slot->uid, desired[spec].uid) == 0
            && strcmp(slot->owner, desired[spec].owner) == 0;
        if (slot->uidRef) CFRelease(slot->uidRef);
        if (slot->nameRef) CFRelease(slot->nameRef);
        slot->uidRef = uidRef;
        slot->nameRef = nameRef;
        CopyCString(slot->uid, desired[spec].uid);
        slot->latencyFrames = desired[spec].latencyFrames;
        CopyCString(slot->owner, desired[spec].owner);
        slot->deviceID = gNextObjectID++;
        slot->streamID = gNextObjectID++;
        // A display that comes back is a new device to the HAL: nothing of
        // the old one's IO carries over, even if the HAL never stopped it.
        // After the new IDs, so a late StartIO on the old ID cannot land in it.
        pthread_mutex_lock(&slot->ioMutex);
        slot->ioRunCount = 0;
        atomic_store(&slot->ioRunning, false);
        atomic_store_explicit(&slot->writeHead, 0, memory_order_relaxed);
        atomic_fetch_add_explicit(&slot->generation, 1, memory_order_release);
        pthread_mutex_unlock(&slot->ioMutex);
        slot->volumeID = gNextObjectID++;
        slot->muteID = gNextObjectID++;
        if (!sameDisplay) {
            SetVolumeScalar(slot, 1.0f);
            atomic_store(&slot->muted, false);
        }
        slot->everUsed = true;
        slot->active = true;
        changed = true;
    }
    return changed;
}

static void NotifyDeviceListChanged(void) {
    if (gHost == NULL) return;
    AudioObjectPropertyAddress addresses[2] = {
        {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal,
         kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal,
         kAudioObjectPropertyElementMain},
    };
    gHost->PropertiesChanged(gHost, kAudioObjectPlugInObject, 2, addresses);
}

// The token that owns the active device with this UID, if any. Callers hold
// gStateMutex.
static const char* CurrentOwner(const char* uid) {
    for (int index = 0; index < kMaxDevices; ++index) {
        if (gSlots[index].active && strcmp(gSlots[index].uid, uid) == 0) {
            return gSlots[index].owner;
        }
    }
    return NULL;
}

// Runs on gQueue, never on a HAL thread, so the host is told about the new
// device list outside of any call it is in the middle of making.
static void Reconcile(void) {
    DeviceSpec desired[kMaxDevices];
    UInt32 count = 0;
    AudioObjectID renamed[kMaxDevices];
    UInt32 renamedCount = 0;
    bool changed;

    pthread_mutex_lock(&gStateMutex);
    UInt64 now = gNow();
    UInt64 timeout = (UInt64)(gHostTicksPerSecond * (Float64)kClientTimeoutSeconds);
    for (int client = 0; client < kMaxClients; ++client) {
        if (gClients[client].used && now - gClients[client].lastSeenHostTime > timeout) {
            gClients[client].used = false;
        }
    }
    // Two passes. First every device whose owner is still alive and still
    // lists it, from that owner alone, so nothing another client lists can
    // crowd it out or take it over. Then new devices, first lister owning.
    for (int pass = 0; pass < 2; ++pass) {
        for (int client = 0; client < kMaxClients; ++client) {
            if (!gClients[client].used) continue;
            for (UInt32 index = 0; index < gClients[client].deviceCount; ++index) {
                const DeviceSpec* spec = &gClients[client].devices[index];
                const char* current = CurrentOwner(spec->uid);
                bool owned = current != NULL && strcmp(current, gClients[client].token) == 0;
                if (pass == 0 && !owned) continue;
                bool seen = false;
                for (UInt32 other = 0; other < count; ++other) {
                    if (strcmp(desired[other].uid, spec->uid) == 0) seen = true;
                }
                if (seen || count >= kMaxDevices) continue;
                desired[count] = *spec;
                CopyCString(desired[count].owner, gClients[client].token);
                ++count;
            }
        }
    }
    changed = ApplyDesiredDevices(desired, count, renamed, &renamedCount);
    pthread_mutex_unlock(&gStateMutex);

    if (changed) NotifyDeviceListChanged();
    for (UInt32 index = 0; index < renamedCount && gHost != NULL; ++index) {
        AudioObjectPropertyAddress name = {
            kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        gHost->PropertiesChanged(gHost, renamed[index], 1, &name);
    }
}

// Parses one registration. The caller holds gStateMutex.
static OSStatus Register(CFPropertyListRef plist) {
    if (plist == NULL || CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
        return kAudioHardwareIllegalOperationError;
    }
    CFDictionaryRef dictionary = (CFDictionaryRef)plist;
    CFTypeRef version = CFDictionaryGetValue(dictionary, CFSTR(ESPDISP_AUDIO_KEY_VERSION));
    SInt32 versionValue = 0;
    if (version == NULL || CFGetTypeID(version) != CFNumberGetTypeID()
        || !CFNumberGetValue((CFNumberRef)version, kCFNumberSInt32Type, &versionValue)
        || versionValue != ESPDISP_AUDIO_PROTOCOL_VERSION) {
        return kAudioHardwareUnsupportedOperationError;
    }
    char clientID[kMaxStringBytes];
    if (!CStringFromCF(CFDictionaryGetValue(dictionary, CFSTR(ESPDISP_AUDIO_KEY_CLIENT)),
                       clientID)) {
        return kAudioHardwareIllegalOperationError;
    }
    CFTypeRef list = CFDictionaryGetValue(dictionary, CFSTR(ESPDISP_AUDIO_KEY_DEVICES));
    if (list == NULL || CFGetTypeID(list) != CFArrayGetTypeID()) {
        return kAudioHardwareIllegalOperationError;
    }

    Client parsed;
    memset(&parsed, 0, sizeof parsed);
    CopyCString(parsed.id, clientID);
    if (!CStringFromCF(CFDictionaryGetValue(dictionary, CFSTR(ESPDISP_AUDIO_KEY_TOKEN)),
                       parsed.token)
        || strlen(parsed.token) < ESPDISP_AUDIO_MIN_TOKEN_BYTES) {
        return kAudioHardwareIllegalOperationError;
    }
    CFIndex total = CFArrayGetCount((CFArrayRef)list);
    for (CFIndex index = 0; index < total && parsed.deviceCount < kMaxDevices; ++index) {
        CFTypeRef entry = CFArrayGetValueAtIndex((CFArrayRef)list, index);
        if (entry == NULL || CFGetTypeID(entry) != CFDictionaryGetTypeID()) continue;
        DeviceSpec spec;
        memset(&spec, 0, sizeof spec);
        if (!CStringFromCF(CFDictionaryGetValue(
                (CFDictionaryRef)entry, CFSTR(ESPDISP_AUDIO_KEY_UID)), spec.uid)
            || !CStringFromCF(CFDictionaryGetValue(
                (CFDictionaryRef)entry, CFSTR(ESPDISP_AUDIO_KEY_NAME)), spec.name)) {
            continue;
        }
        CFTypeRef latency = CFDictionaryGetValue(
            (CFDictionaryRef)entry, CFSTR(ESPDISP_AUDIO_KEY_LATENCY));
        SInt32 latencyValue = 0;
        if (latency != NULL && CFGetTypeID(latency) == CFNumberGetTypeID()
            && CFNumberGetValue((CFNumberRef)latency, kCFNumberSInt32Type, &latencyValue)
            && latencyValue > 0 && latencyValue <= kRingFrames) {
            spec.latencyFrames = (UInt32)latencyValue;
        }
        parsed.devices[parsed.deviceCount++] = spec;
    }

    int slot = -1;
    for (int index = 0; index < kMaxClients; ++index) {
        if (gClients[index].used && strcmp(gClients[index].token, parsed.token) == 0) {
            slot = index;
        }
    }
    if (parsed.deviceCount == 0) {
        // An empty list is how a client says goodbye.
        if (slot >= 0) gClients[slot].used = false;
        return kAudioHardwareNoError;
    }
    if (slot < 0) {
        for (int index = 0; index < kMaxClients && slot < 0; ++index) {
            if (!gClients[index].used) slot = index;
        }
    }
    if (slot < 0) return kAudioHardwareIllegalOperationError;
    parsed.used = true;
    parsed.lastSeenHostTime = gNow();
    gClients[slot] = parsed;
    return kAudioHardwareNoError;
}

static CFDictionaryRef CopyRegistrationSummary(void) {
    CFMutableArrayRef uids = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (int index = 0; index < kMaxDevices; ++index) {
        if (gSlots[index].active) CFArrayAppendValue(uids, gSlots[index].uidRef);
    }
    const void* keys[] = {CFSTR(ESPDISP_AUDIO_KEY_DEVICES)};
    const void* values[] = {uids};
    CFDictionaryRef summary = CFDictionaryCreate(
        NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFRelease(uids);
    return summary;
}

#pragma mark - Ring

// Called on the IO thread: no locks, no allocation.
static void WriteMix(DeviceSlot* slot, Float64 sampleTime, UInt32 frames,
                     const Float32* buffer) {
    if (slot->ring == NULL || buffer == NULL || !(sampleTime >= 0)) return;
    if (frames > kRingFrames) frames = kRingFrames;
    UInt64 start = (UInt64)sampleTime;
    UInt64 head = atomic_load_explicit(&slot->writeHead, memory_order_relaxed);
    // A skipped cycle leaves a hole; fill it with silence rather than with
    // whatever the ring held a second ago.
    if (start > head) {
        UInt64 gap = start - head;
        if (gap > kRingFrames) gap = kRingFrames;
        for (UInt64 frame = start - gap; frame < start; ++frame) {
            Float32* out = slot->ring + (frame % kRingFrames) * kChannels;
            out[0] = 0;
            out[1] = 0;
        }
    }
    Float32 gain = 0.0f;
    if (!atomic_load_explicit(&slot->muted, memory_order_relaxed)) {
        Float32 scalar = VolumeScalar(slot);
        gain = scalar * scalar;
    }
    for (UInt32 frame = 0; frame < frames; ++frame) {
        Float32* out = slot->ring + ((start + frame) % kRingFrames) * kChannels;
        out[0] = buffer[frame * kChannels] * gain;
        out[1] = buffer[frame * kChannels + 1] * gain;
    }
    UInt64 end = start + frames;
    if (end > head) {
        atomic_store_explicit(&slot->writeHead, end, memory_order_release);
    }
}

// Everything written since the last read, at most kMaxReadFrames of the
// newest, as interleaved stereo Float32. A reader that fell behind skips the
// oldest frames rather than adding their delay to the display.
static CFDataRef CopyPendingFrames(DeviceSlot* slot) {
    pthread_mutex_lock(&slot->readMutex);
    UInt64 generation = atomic_load_explicit(&slot->generation, memory_order_acquire);
    UInt64 head = atomic_load_explicit(&slot->writeHead, memory_order_acquire);
    // A device macOS is not running IO on is not the Mac's output: whatever
    // was mixed before it stopped and not yet read is dropped, so a device
    // just switched away from hands over nothing, not its last 100 ms.
    if (!atomic_load(&slot->ioRunning)) {
        slot->readGeneration = generation;
        slot->readCursor = head;
    }
    if (generation != slot->readGeneration || slot->readCursor > head) {
        slot->readGeneration = generation;
        slot->readCursor = head > kMaxReadFrames ? head - kMaxReadFrames : 0;
    }
    if (head - slot->readCursor > kMaxReadFrames) {
        slot->readCursor = head - kMaxReadFrames;
    }
    UInt64 frames = head - slot->readCursor;
    CFMutableDataRef data = CFDataCreateMutable(NULL, (CFIndex)(frames * kBytesPerFrame));
    if (data != NULL && slot->ring != NULL && frames > 0) {
        CFDataSetLength(data, (CFIndex)(frames * kBytesPerFrame));
        Float32* out = (Float32*)CFDataGetMutableBytePtr(data);
        for (UInt64 frame = 0; frame < frames; ++frame) {
            const Float32* in = slot->ring + ((slot->readCursor + frame) % kRingFrames) * kChannels;
            out[frame * kChannels] = in[0];
            out[frame * kChannels + 1] = in[1];
        }
    }
    slot->readCursor = head;
    pthread_mutex_unlock(&slot->readMutex);
    return data;
}

#pragma mark - Plug-in interface declarations

static HRESULT QueryInterface(void*, REFIID, LPVOID*);
static ULONG AddRef(void*);
static ULONG Release(void*);
static OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef,
                             const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID,
                                const AudioServerPlugInClientInfo*);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID,
                                   const AudioServerPlugInClientInfo*);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID,
                                                 UInt64, void*);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID,
                                               UInt64, void*);
static Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                           const AudioObjectPropertyAddress*);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                                   const AudioObjectPropertyAddress*, Boolean*);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                                    const AudioObjectPropertyAddress*, UInt32, const void*,
                                    UInt32*);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                                const AudioObjectPropertyAddress*, UInt32, const void*,
                                UInt32, UInt32*, void*);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                                const AudioObjectPropertyAddress*, UInt32, const void*,
                                UInt32, const void*);
static OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32,
                                 Float64*, UInt64*, UInt64*);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                                  Boolean*, Boolean*);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                                 UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID,
                              UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*,
                              void*, void*);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                               UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePointer;

static bool IsDriver(AudioServerPlugInDriverRef driver) { return driver == gDriverRef; }

#pragma mark - Factory and IUnknown

__attribute__((visibility("default")))
void* ESPDisplayAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

void* ESPDisplayAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

static HRESULT QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface) {
    if (driver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID)
        || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void* driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Release(void* driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

#pragma mark - Basic operations

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    gHost = host;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gHostTicksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = gHostTicksPerSecond / kSampleRate;
    for (int index = 0; index < kMaxDevices; ++index) {
        pthread_mutex_init(&gSlots[index].ioMutex, NULL);
        pthread_mutex_init(&gSlots[index].readMutex, NULL);
        SetVolumeScalar(&gSlots[index], 1.0f);
    }
    if (gQueue == NULL) {
        gQueue = dispatch_queue_create("com.espdisplay.audio-driver", DISPATCH_QUEUE_SERIAL);
        gExpiryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(gExpiryTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(gExpiryTimer, ^{ Reconcile(); });
        dispatch_resume(gExpiryTimer);
    }
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description,
                             const AudioServerPlugInClientInfo* client,
                             AudioObjectID* outDeviceID) {
    (void)driver; (void)description; (void)client; (void)outDeviceID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceID) {
    (void)driver; (void)deviceID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceID,
                                const AudioServerPlugInClientInfo* client) {
    (void)client;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    return IOSlot(deviceID) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceID,
                                   const AudioServerPlugInClientInfo* client) {
    (void)client;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    return IOSlot(deviceID) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                                 AudioObjectID deviceID, UInt64 action,
                                                 void* info) {
    (void)driver; (void)deviceID; (void)action; (void)info;
    return kAudioHardwareNoError;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                               AudioObjectID deviceID, UInt64 action,
                                               void* info) {
    (void)driver; (void)deviceID; (void)action; (void)info;
    return kAudioHardwareNoError;
}

#pragma mark - Properties

static const AudioServerPlugInCustomPropertyInfo kPlugInCustomProperties[] = {
    {ESPDISP_AUDIO_SELECTOR_REGISTER, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
     kAudioServerPlugInCustomPropertyDataTypeNone},
    {ESPDISP_AUDIO_SELECTOR_VERSION, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
     kAudioServerPlugInCustomPropertyDataTypeNone},
};

static const AudioServerPlugInCustomPropertyInfo kDeviceCustomProperties[] = {
    {ESPDISP_AUDIO_SELECTOR_PCM, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
     kAudioServerPlugInCustomPropertyDataTypeCFString},
    {ESPDISP_AUDIO_SELECTOR_OWNED, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
     kAudioServerPlugInCustomPropertyDataTypeCFString},
};

static bool IsInputScope(const AudioObjectPropertyAddress* address) {
    return address->mScope == kAudioObjectPropertyScopeInput;
}

static bool PlugInHas(AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyManufacturer:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
    case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioPlugInPropertyResourceBundle:
    case kAudioObjectPropertyCustomPropertyInfoList:
    case ESPDISP_AUDIO_SELECTOR_REGISTER:
    case ESPDISP_AUDIO_SELECTOR_VERSION:
        return true;
    default:
        return false;
    }
}

static bool DeviceHas(AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioObjectPropertyCustomPropertyInfoList:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyRelatedDevices:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertyStreams:
    case kAudioObjectPropertyControlList:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyPreferredChannelsForStereo:
    case kAudioDevicePropertyPreferredChannelLayout:
    case kAudioDevicePropertyConfigurationApplication:
    case ESPDISP_AUDIO_SELECTOR_PCM:
    case ESPDISP_AUDIO_SELECTOR_OWNED:
        return true;
    default:
        return false;
    }
}

static bool StreamHas(AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:
    case kAudioStreamPropertyLatency:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        return true;
    default:
        return false;
    }
}

static bool ControlHas(ObjectKind kind, AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioControlPropertyScope:
    case kAudioControlPropertyElement:
        return true;
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue:
    case kAudioLevelControlPropertyDecibelRange:
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        return kind == kObjectVolume;
    case kAudioBooleanControlPropertyValue:
        return kind == kObjectMute;
    default:
        return false;
    }
}

static bool Has(ObjectKind kind, const AudioObjectPropertyAddress* address) {
    switch (kind) {
    case kObjectPlugIn: return PlugInHas(address->mSelector);
    case kObjectDevice: return DeviceHas(address->mSelector);
    case kObjectStream: return StreamHas(address->mSelector);
    case kObjectVolume:
    case kObjectMute: return ControlHas(kind, address->mSelector);
    case kObjectNone: return false;
    }
    return false;
}

static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                           pid_t clientPID, const AudioObjectPropertyAddress* address) {
    (void)clientPID;
    if (!IsDriver(driver) || address == NULL) return false;
    pthread_mutex_lock(&gStateMutex);
    DeviceSlot* slot;
    bool has = Has(Resolve(objectID, &slot), address);
    pthread_mutex_unlock(&gStateMutex);
    return has;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                   pid_t clientPID, const AudioObjectPropertyAddress* address,
                                   Boolean* outIsSettable) {
    (void)clientPID;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    if (address == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    DeviceSlot* slot;
    ObjectKind kind = Resolve(objectID, &slot);
    OSStatus status = kAudioHardwareNoError;
    if (kind == kObjectNone) {
        status = kAudioHardwareBadObjectError;
    } else if (!Has(kind, address)) {
        status = kAudioHardwareUnknownPropertyError;
    } else {
        AudioObjectPropertySelector selector = address->mSelector;
        *outIsSettable =
            (kind == kObjectPlugIn && selector == ESPDISP_AUDIO_SELECTOR_REGISTER)
            || (kind == kObjectVolume && (selector == kAudioLevelControlPropertyScalarValue
                                          || selector == kAudioLevelControlPropertyDecibelValue))
            || (kind == kObjectMute && selector == kAudioBooleanControlPropertyValue);
    }
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static UInt32 ActiveDeviceCount(void) {
    UInt32 count = 0;
    for (int index = 0; index < kMaxDevices; ++index) {
        if (gSlots[index].active) ++count;
    }
    return count;
}

static UInt32 PreferredLayoutSize(void) {
    return (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions)
                    + kChannels * sizeof(AudioChannelDescription));
}

// The size of one property; callers hold gStateMutex and have checked Has().
static UInt32 DataSize(ObjectKind kind, const DeviceSlot* slot,
                       const AudioObjectPropertyAddress* address) {
    AudioObjectPropertySelector selector = address->mSelector;
    switch (selector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
        return sizeof(AudioClassID);
    case kAudioObjectPropertyOwner:
        return sizeof(AudioObjectID);
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kAudioPlugInPropertyResourceBundle:
    case kAudioDevicePropertyConfigurationApplication:
        return sizeof(CFStringRef);
    case ESPDISP_AUDIO_SELECTOR_REGISTER:
    case ESPDISP_AUDIO_SELECTOR_VERSION:
    case ESPDISP_AUDIO_SELECTOR_PCM:
    case ESPDISP_AUDIO_SELECTOR_OWNED:
        return sizeof(CFPropertyListRef);
    case kAudioObjectPropertyCustomPropertyInfoList:
        return kind == kObjectPlugIn ? sizeof kPlugInCustomProperties
                                     : sizeof kDeviceCustomProperties;
    default:
        break;
    }
    switch (kind) {
    case kObjectPlugIn:
        switch (selector) {
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            return ActiveDeviceCount() * (UInt32)sizeof(AudioObjectID);
        case kAudioPlugInPropertyTranslateUIDToDevice:
            return sizeof(AudioObjectID);
        }
        break;
    case kObjectDevice:
        (void)slot;
        switch (selector) {
        case kAudioObjectPropertyOwnedObjects:
            return IsInputScope(address) ? 0 : 3 * (UInt32)sizeof(AudioObjectID);
        case kAudioDevicePropertyStreams:
            return IsInputScope(address) ? 0 : (UInt32)sizeof(AudioObjectID);
        case kAudioObjectPropertyControlList:
            return 2 * (UInt32)sizeof(AudioObjectID);
        case kAudioDevicePropertyRelatedDevices:
            return sizeof(AudioObjectID);
        case kAudioDevicePropertyNominalSampleRate:
            return sizeof(Float64);
        case kAudioDevicePropertyAvailableNominalSampleRates:
            return sizeof(AudioValueRange);
        case kAudioDevicePropertyPreferredChannelsForStereo:
            return 2 * (UInt32)sizeof(UInt32);
        case kAudioDevicePropertyPreferredChannelLayout:
            return PreferredLayoutSize();
        default:
            return sizeof(UInt32);
        }
    case kObjectStream:
        switch (selector) {
        case kAudioObjectPropertyOwnedObjects:
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return sizeof(AudioStreamBasicDescription);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return sizeof(AudioStreamRangedDescription);
        default:
            return sizeof(UInt32);
        }
    case kObjectVolume:
    case kObjectMute:
        switch (selector) {
        case kAudioObjectPropertyOwnedObjects:
            return 0;
        case kAudioControlPropertyScope:
            return sizeof(AudioObjectPropertyScope);
        case kAudioControlPropertyElement:
            return sizeof(AudioObjectPropertyElement);
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            return sizeof(Float32);
        case kAudioLevelControlPropertyDecibelRange:
            return sizeof(AudioValueRange);
        default:
            return sizeof(UInt32);
        }
    case kObjectNone:
        break;
    }
    return 0;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                    pid_t clientPID, const AudioObjectPropertyAddress* address,
                                    UInt32 qualifierSize, const void* qualifier,
                                    UInt32* outDataSize) {
    (void)clientPID; (void)qualifierSize; (void)qualifier;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    if (address == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    DeviceSlot* slot;
    ObjectKind kind = Resolve(objectID, &slot);
    OSStatus status = kAudioHardwareNoError;
    if (kind == kObjectNone) {
        status = kAudioHardwareBadObjectError;
    } else if (!Has(kind, address)) {
        status = kAudioHardwareUnknownPropertyError;
    } else {
        *outDataSize = DataSize(kind, slot, address);
    }
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

#define WRITE_VALUE(type, value)                                     \
    do {                                                             \
        if (dataSize < sizeof(type)) {                               \
            status = kAudioHardwareBadPropertySizeError;             \
            break;                                                   \
        }                                                            \
        *(type*)outData = (value);                                   \
        *outDataSize = sizeof(type);                                 \
    } while (0)

static OSStatus GetPlugInProperty(const AudioObjectPropertyAddress* address,
                                  UInt32 qualifierSize, const void* qualifier,
                                  UInt32 dataSize, UInt32* outDataSize, void* outData) {
    OSStatus status = kAudioHardwareNoError;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kAudioObjectClassID);
        break;
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kAudioPlugInClassID);
        break;
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, kAudioObjectUnknown);
        break;
    case kAudioObjectPropertyManufacturer:
        WRITE_VALUE(CFStringRef, CFSTR("ESPDisplay"));
        break;
    case kAudioPlugInPropertyResourceBundle:
        WRITE_VALUE(CFStringRef, CFSTR(""));
        break;
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        UInt32 capacity = dataSize / (UInt32)sizeof(AudioObjectID);
        UInt32 written = 0;
        for (int index = 0; index < kMaxDevices && written < capacity; ++index) {
            if (gSlots[index].active) {
                ((AudioObjectID*)outData)[written++] = gSlots[index].deviceID;
            }
        }
        *outDataSize = written * (UInt32)sizeof(AudioObjectID);
        break;
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (dataSize < sizeof(AudioObjectID)) {
            status = kAudioHardwareBadPropertySizeError;
            break;
        }
        if (qualifierSize < sizeof(CFStringRef) || qualifier == NULL) {
            status = kAudioHardwareIllegalOperationError;
            break;
        }
        CFStringRef wanted = *(const CFStringRef*)qualifier;
        AudioObjectID found = kAudioObjectUnknown;
        for (int index = 0; index < kMaxDevices && wanted != NULL; ++index) {
            if (gSlots[index].active
                && CFStringCompare(gSlots[index].uidRef, wanted, 0) == kCFCompareEqualTo) {
                found = gSlots[index].deviceID;
            }
        }
        *(AudioObjectID*)outData = found;
        *outDataSize = sizeof(AudioObjectID);
        break;
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        UInt32 size = (UInt32)sizeof kPlugInCustomProperties;
        if (dataSize < size) size = dataSize - dataSize % sizeof kPlugInCustomProperties[0];
        memcpy(outData, kPlugInCustomProperties, size);
        *outDataSize = size;
        break;
    }
    case ESPDISP_AUDIO_SELECTOR_REGISTER:
        WRITE_VALUE(CFPropertyListRef, CopyRegistrationSummary());
        break;
    case ESPDISP_AUDIO_SELECTOR_VERSION: {
        SInt32 version = ESPDISP_AUDIO_PROTOCOL_VERSION;
        WRITE_VALUE(CFPropertyListRef, CFNumberCreate(NULL, kCFNumberSInt32Type, &version));
        break;
    }
    default:
        status = kAudioHardwareUnknownPropertyError;
    }
    return status;
}

// The read's qualifier is the owner's token.
static bool MayRead(const DeviceSlot* slot, UInt32 qualifierSize, const void* qualifier) {
    if (qualifier == NULL || qualifierSize < sizeof(CFStringRef)) return false;
    char token[kMaxStringBytes];
    return CStringFromCF(*(const CFStringRef*)qualifier, token) && slot->owner[0] != 0
        && strcmp(token, slot->owner) == 0;
}

static OSStatus GetDeviceProperty(DeviceSlot* slot, UInt32 qualifierSize,
                                  const void* qualifier,
                                  const AudioObjectPropertyAddress* address,
                                  UInt32 dataSize, UInt32* outDataSize, void* outData) {
    OSStatus status = kAudioHardwareNoError;
    bool input = IsInputScope(address);
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kAudioObjectClassID);
        break;
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kAudioDeviceClassID);
        break;
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, kAudioObjectPlugInObject);
        break;
    case kAudioObjectPropertyName:
        WRITE_VALUE(CFStringRef, (CFStringRef)CFRetain(slot->nameRef));
        break;
    case kAudioObjectPropertyManufacturer:
        WRITE_VALUE(CFStringRef, CFSTR("ESPDisplay"));
        break;
    case kAudioDevicePropertyDeviceUID:
        WRITE_VALUE(CFStringRef, (CFStringRef)CFRetain(slot->uidRef));
        break;
    case kAudioDevicePropertyModelUID:
        WRITE_VALUE(CFStringRef, CFSTR(ESPDISP_AUDIO_MODEL_UID));
        break;
    case kAudioDevicePropertyConfigurationApplication:
        WRITE_VALUE(CFStringRef, CFSTR("com.apple.audio.AudioMIDISetup"));
        break;
    case kAudioObjectPropertyOwnedObjects: {
        AudioObjectID owned[3] = {slot->streamID, slot->volumeID, slot->muteID};
        UInt32 count = input ? 0 : 3;
        UInt32 capacity = dataSize / (UInt32)sizeof(AudioObjectID);
        if (count > capacity) count = capacity;
        memcpy(outData, owned, count * sizeof(AudioObjectID));
        *outDataSize = count * (UInt32)sizeof(AudioObjectID);
        break;
    }
    case kAudioDevicePropertyStreams: {
        UInt32 count = (input || dataSize < sizeof(AudioObjectID)) ? 0 : 1;
        if (count) *(AudioObjectID*)outData = slot->streamID;
        *outDataSize = count * (UInt32)sizeof(AudioObjectID);
        break;
    }
    case kAudioObjectPropertyControlList: {
        AudioObjectID controls[2] = {slot->volumeID, slot->muteID};
        UInt32 count = dataSize / (UInt32)sizeof(AudioObjectID);
        if (count > 2) count = 2;
        memcpy(outData, controls, count * sizeof(AudioObjectID));
        *outDataSize = count * (UInt32)sizeof(AudioObjectID);
        break;
    }
    case kAudioDevicePropertyRelatedDevices:
        WRITE_VALUE(AudioObjectID, slot->deviceID);
        break;
    case kAudioDevicePropertyTransportType:
        WRITE_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        break;
    case kAudioDevicePropertyClockDomain:
        WRITE_VALUE(UInt32, 0);
        break;
    case kAudioDevicePropertyDeviceIsAlive:
        WRITE_VALUE(UInt32, 1);
        break;
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&slot->ioMutex);
        UInt32 running = slot->ioRunCount > 0;
        pthread_mutex_unlock(&slot->ioMutex);
        WRITE_VALUE(UInt32, running);
        break;
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        // Output only: the device has no input stream to be a default for.
        WRITE_VALUE(UInt32, input ? 0 : 1);
        break;
    case kAudioDevicePropertyLatency:
        WRITE_VALUE(UInt32, input ? 0 : slot->latencyFrames);
        break;
    case kAudioDevicePropertySafetyOffset:
        WRITE_VALUE(UInt32, 0);
        break;
    case kAudioDevicePropertyNominalSampleRate:
        WRITE_VALUE(Float64, kSampleRate);
        break;
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = {kSampleRate, kSampleRate};
        WRITE_VALUE(AudioValueRange, range);
        break;
    }
    case kAudioDevicePropertyIsHidden:
        WRITE_VALUE(UInt32, 0);
        break;
    case kAudioDevicePropertyZeroTimeStampPeriod:
        WRITE_VALUE(UInt32, kZeroTimeStampPeriod);
        break;
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (dataSize < 2 * sizeof(UInt32)) {
            status = kAudioHardwareBadPropertySizeError;
            break;
        }
        ((UInt32*)outData)[0] = 1;
        ((UInt32*)outData)[1] = 2;
        *outDataSize = 2 * (UInt32)sizeof(UInt32);
        break;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 size = PreferredLayoutSize();
        if (dataSize < size) {
            status = kAudioHardwareBadPropertySizeError;
            break;
        }
        AudioChannelLayout* layout = outData;
        memset(layout, 0, size);
        layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        layout->mNumberChannelDescriptions = kChannels;
        layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
        layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
        *outDataSize = size;
        break;
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        UInt32 size = (UInt32)sizeof kDeviceCustomProperties;
        if (dataSize < size) {
            status = kAudioHardwareBadPropertySizeError;
            break;
        }
        memcpy(outData, kDeviceCustomProperties, size);
        *outDataSize = size;
        break;
    }
    case ESPDISP_AUDIO_SELECTOR_OWNED: {
        // Lets the app check, without taking any frames, that a device it is
        // about to route the Mac's sound to really is its own.
        SInt32 owned = MayRead(slot, qualifierSize, qualifier) ? 1 : 0;
        WRITE_VALUE(CFPropertyListRef, CFNumberCreate(NULL, kCFNumberSInt32Type, &owned));
        break;
    }
    case ESPDISP_AUDIO_SELECTOR_PCM:
        if (dataSize < sizeof(CFPropertyListRef)) {
            status = kAudioHardwareBadPropertySizeError;
            break;
        }
        // What the Mac plays is private: only the client that owns this
        // display may read it, or any app could record the Mac's sound
        // without the recording permission, and take frames from the app.
        if (!MayRead(slot, qualifierSize, qualifier)) {
            status = kAudioHardwareIllegalOperationError;
            break;
        }
        *(CFPropertyListRef*)outData = CopyPendingFrames(slot);
        *outDataSize = sizeof(CFPropertyListRef);
        break;
    default:
        status = kAudioHardwareUnknownPropertyError;
    }
    return status;
}

static OSStatus GetStreamProperty(DeviceSlot* slot, const AudioObjectPropertyAddress* address,
                                  UInt32 dataSize, UInt32* outDataSize, void* outData) {
    OSStatus status = kAudioHardwareNoError;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kAudioObjectClassID);
        break;
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kAudioStreamClassID);
        break;
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, slot->deviceID);
        break;
    case kAudioObjectPropertyOwnedObjects:
        *outDataSize = 0;
        break;
    case kAudioStreamPropertyIsActive:
        WRITE_VALUE(UInt32, 1);
        break;
    case kAudioStreamPropertyDirection:
        WRITE_VALUE(UInt32, 0);
        break;
    case kAudioStreamPropertyTerminalType:
        WRITE_VALUE(UInt32, kAudioStreamTerminalTypeSpeaker);
        break;
    case kAudioStreamPropertyStartingChannel:
        WRITE_VALUE(UInt32, 1);
        break;
    case kAudioStreamPropertyLatency:
        WRITE_VALUE(UInt32, 0);
        break;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        AudioStreamBasicDescription format;
        FillFormat(&format);
        WRITE_VALUE(AudioStreamBasicDescription, format);
        break;
    }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription ranged;
        FillFormat(&ranged.mFormat);
        ranged.mSampleRateRange.mMinimum = kSampleRate;
        ranged.mSampleRateRange.mMaximum = kSampleRate;
        WRITE_VALUE(AudioStreamRangedDescription, ranged);
        break;
    }
    default:
        status = kAudioHardwareUnknownPropertyError;
    }
    return status;
}

static OSStatus GetControlProperty(ObjectKind kind, DeviceSlot* slot,
                                   const AudioObjectPropertyAddress* address, UInt32 dataSize,
                                   UInt32* outDataSize, void* outData) {
    OSStatus status = kAudioHardwareNoError;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kind == kObjectVolume ? kAudioLevelControlClassID
                                                        : kAudioBooleanControlClassID);
        break;
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kind == kObjectVolume ? kAudioVolumeControlClassID
                                                        : kAudioMuteControlClassID);
        break;
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, slot->deviceID);
        break;
    case kAudioObjectPropertyOwnedObjects:
        *outDataSize = 0;
        break;
    case kAudioControlPropertyScope:
        WRITE_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        break;
    case kAudioControlPropertyElement:
        WRITE_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        break;
    case kAudioLevelControlPropertyScalarValue:
        WRITE_VALUE(Float32, VolumeScalar(slot));
        break;
    case kAudioLevelControlPropertyDecibelValue:
        WRITE_VALUE(Float32, ScalarToDecibels(VolumeScalar(slot)));
        break;
    case kAudioLevelControlPropertyDecibelRange: {
        AudioValueRange range = {kMinimumDecibels, 0};
        WRITE_VALUE(AudioValueRange, range);
        break;
    }
    case kAudioLevelControlPropertyConvertScalarToDecibels:
        if (dataSize < sizeof(Float32)) {
            status = kAudioHardwareBadPropertySizeError;
            break;
        }
        *(Float32*)outData = ScalarToDecibels(*(Float32*)outData);
        *outDataSize = sizeof(Float32);
        break;
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        if (dataSize < sizeof(Float32)) {
            status = kAudioHardwareBadPropertySizeError;
            break;
        }
        *(Float32*)outData = DecibelsToScalar(*(Float32*)outData);
        *outDataSize = sizeof(Float32);
        break;
    case kAudioBooleanControlPropertyValue:
        WRITE_VALUE(UInt32, atomic_load(&slot->muted) ? 1 : 0);
        break;
    default:
        status = kAudioHardwareUnknownPropertyError;
    }
    return status;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                pid_t clientPID, const AudioObjectPropertyAddress* address,
                                UInt32 qualifierSize, const void* qualifier, UInt32 dataSize,
                                UInt32* outDataSize, void* outData) {
    (void)clientPID;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    if (address == NULL || outDataSize == NULL || (outData == NULL && dataSize > 0)) {
        return kAudioHardwareIllegalOperationError;
    }
    pthread_mutex_lock(&gStateMutex);
    DeviceSlot* slot;
    ObjectKind kind = Resolve(objectID, &slot);
    OSStatus status;
    if (kind == kObjectNone) {
        status = kAudioHardwareBadObjectError;
    } else if (!Has(kind, address)) {
        status = kAudioHardwareUnknownPropertyError;
    } else if (outData == NULL) {
        status = kAudioHardwareBadPropertySizeError;
    } else {
        switch (kind) {
        case kObjectPlugIn:
            status = GetPlugInProperty(address, qualifierSize, qualifier, dataSize,
                                       outDataSize, outData);
            break;
        case kObjectDevice:
            status = GetDeviceProperty(slot, qualifierSize, qualifier, address, dataSize,
                                       outDataSize, outData);
            break;
        case kObjectStream:
            status = GetStreamProperty(slot, address, dataSize, outDataSize, outData);
            break;
        default:
            status = GetControlProperty(kind, slot, address, dataSize, outDataSize, outData);
            break;
        }
    }
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                pid_t clientPID, const AudioObjectPropertyAddress* address,
                                UInt32 qualifierSize, const void* qualifier, UInt32 dataSize,
                                const void* data) {
    (void)clientPID; (void)qualifierSize; (void)qualifier;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    if (address == NULL || data == NULL) return kAudioHardwareIllegalOperationError;
    AudioObjectPropertyAddress changed[2];
    UInt32 changedCount = 0;
    AudioObjectID changedObject = kAudioObjectUnknown;
    bool reconcile = false;

    pthread_mutex_lock(&gStateMutex);
    DeviceSlot* slot;
    ObjectKind kind = Resolve(objectID, &slot);
    OSStatus status = kAudioHardwareNoError;
    AudioObjectPropertySelector selector = address->mSelector;
    if (kind == kObjectNone) {
        status = kAudioHardwareBadObjectError;
    } else if (!Has(kind, address)) {
        status = kAudioHardwareUnknownPropertyError;
    } else if (kind == kObjectPlugIn && selector == ESPDISP_AUDIO_SELECTOR_REGISTER) {
        if (dataSize < sizeof(CFPropertyListRef)) {
            status = kAudioHardwareBadPropertySizeError;
        } else {
            status = Register(*(const CFPropertyListRef*)data);
            reconcile = status == kAudioHardwareNoError;
        }
    } else if (kind == kObjectVolume && (selector == kAudioLevelControlPropertyScalarValue
                                         || selector == kAudioLevelControlPropertyDecibelValue)) {
        if (dataSize < sizeof(Float32)) {
            status = kAudioHardwareBadPropertySizeError;
        } else {
            Float32 value = *(const Float32*)data;
            Float32 scalar = selector == kAudioLevelControlPropertyScalarValue
                ? value : DecibelsToScalar(value);
            if (scalar != VolumeScalar(slot)) {
                SetVolumeScalar(slot, scalar);
                changedObject = slot->volumeID;
                changed[0] = (AudioObjectPropertyAddress){
                    kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain};
                changed[1] = (AudioObjectPropertyAddress){
                    kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain};
                changedCount = 2;
            }
        }
    } else if (kind == kObjectMute && selector == kAudioBooleanControlPropertyValue) {
        if (dataSize < sizeof(UInt32)) {
            status = kAudioHardwareBadPropertySizeError;
        } else {
            bool muted = *(const UInt32*)data != 0;
            if (muted != atomic_load(&slot->muted)) {
                atomic_store(&slot->muted, muted);
                changedObject = slot->muteID;
                changed[0] = (AudioObjectPropertyAddress){
                    kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain};
                changedCount = 1;
            }
        }
    } else {
        status = kAudioHardwareUnsupportedOperationError;
    }
    pthread_mutex_unlock(&gStateMutex);

    if (changedCount > 0 && gHost != NULL) {
        gHost->PropertiesChanged(gHost, changedObject, changedCount, changed);
    }
    if (reconcile && gQueue != NULL) {
        dispatch_async(gQueue, ^{ Reconcile(); });
    }
    return status;
}

#pragma mark - IO

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceID,
                        UInt32 clientID) {
    (void)clientID;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    DeviceSlot* slot = IOSlot(deviceID);
    if (slot == NULL) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&slot->ioMutex);
    if (slot->ioRunCount == UINT64_MAX) {
        pthread_mutex_unlock(&slot->ioMutex);
        return kAudioHardwareIllegalOperationError;
    }
    if (slot->ioRunCount == 0) {
        slot->timestampCount = 0;
        slot->anchorHostTime = mach_absolute_time();
        atomic_store_explicit(&slot->writeHead, 0, memory_order_relaxed);
        atomic_fetch_add_explicit(&slot->generation, 1, memory_order_release);
    }
    ++slot->ioRunCount;
    atomic_store(&slot->ioRunning, true);
    pthread_mutex_unlock(&slot->ioMutex);
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceID,
                       UInt32 clientID) {
    (void)clientID;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    DeviceSlot* slot = IOSlot(deviceID);
    if (slot == NULL) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&slot->ioMutex);
    OSStatus status = kAudioHardwareNoError;
    if (slot->ioRunCount == 0) {
        status = kAudioHardwareIllegalOperationError;
    } else {
        --slot->ioRunCount;
        if (slot->ioRunCount == 0) atomic_store(&slot->ioRunning, false);
    }
    pthread_mutex_unlock(&slot->ioMutex);
    return status;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceID,
                                 UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime,
                                 UInt64* outSeed) {
    (void)clientID;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    DeviceSlot* slot = IOSlot(deviceID);
    if (slot == NULL) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&slot->ioMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kZeroTimeStampPeriod;
    UInt64 nextHostTime = slot->anchorHostTime
        + (UInt64)((Float64)(slot->timestampCount + 1) * ticksPerPeriod);
    if (nextHostTime <= now) ++slot->timestampCount;
    *outSampleTime = (Float64)(slot->timestampCount * kZeroTimeStampPeriod);
    *outHostTime = slot->anchorHostTime
        + (UInt64)((Float64)slot->timestampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&slot->ioMutex);
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceID,
                                  UInt32 clientID, UInt32 operationID, Boolean* outWillDo,
                                  Boolean* outWillDoInPlace) {
    (void)deviceID; (void)clientID;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    if (outWillDo) *outWillDo = operationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceID,
                                 UInt32 clientID, UInt32 operationID, UInt32 frames,
                                 const AudioServerPlugInIOCycleInfo* cycle) {
    (void)deviceID; (void)clientID; (void)operationID; (void)frames; (void)cycle;
    return IsDriver(driver) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceID,
                              AudioObjectID streamID, UInt32 clientID, UInt32 operationID,
                              UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle,
                              void* mainBuffer, void* secondaryBuffer) {
    (void)clientID; (void)secondaryBuffer;
    if (!IsDriver(driver)) return kAudioHardwareBadObjectError;
    DeviceSlot* slot = IOSlot(deviceID);
    if (slot == NULL || streamID != slot->streamID) return kAudioHardwareBadObjectError;
    if (operationID == kAudioServerPlugInIOOperationWriteMix && cycle != NULL) {
        WriteMix(slot, cycle->mOutputTime.mSampleTime, frames, mainBuffer);
    }
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceID,
                               UInt32 clientID, UInt32 operationID, UInt32 frames,
                               const AudioServerPlugInIOCycleInfo* cycle) {
    (void)deviceID; (void)clientID; (void)operationID; (void)frames; (void)cycle;
    return IsDriver(driver) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

#ifdef ESPDISP_AUDIO_DRIVER_TESTING
// Hooks for the host test, which runs this file without coreaudiod.
void ESPDisplayAudio_TestSetClock(UInt64 (*now)(void));
void ESPDisplayAudio_TestReconcileNow(void);

void ESPDisplayAudio_TestSetClock(UInt64 (*now)(void)) { gNow = now ? now : mach_absolute_time; }

void ESPDisplayAudio_TestReconcileNow(void) {
    // Drains the asynchronous reconcile a registration queued, then runs one
    // more, as the expiry timer would.
    dispatch_sync(gQueue, ^{});
    Reconcile();
}
#endif
