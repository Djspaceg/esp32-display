// Host test for ESPDisplayAudio.c: drives the plug-in through its interface
// the way coreaudiod does, with a fake host, so the device list, the
// properties, the volume and the PCM bridge can be checked without installing
// anything. Built with ESPDISP_AUDIO_DRIVER_TESTING for the clock hook.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../ESPDisplayAudioProtocol.h"

void* ESPDisplayAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void ESPDisplayAudio_TestSetClock(UInt64 (*now)(void));
void ESPDisplayAudio_TestReconcileNow(void);

static int gFailures = 0;
#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,    \
                    #condition);                                                \
            ++gFailures;                                                        \
        }                                                                       \
    } while (0)

static AudioServerPlugInDriverRef gDriver;
// The secret the calls below are made with, as each client's own.
static const char* gToken = "app-token-0123456789abcdef0123456789";

#pragma mark - Fake host

static pthread_mutex_t gHostMutex = PTHREAD_MUTEX_INITIALIZER;
static int gDeviceListChanges = 0;
static int gNameChanges = 0;
static int gVolumeChanges = 0;

static OSStatus HostPropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID objectID,
                                      UInt32 count, const AudioObjectPropertyAddress* addresses) {
    (void)host;
    pthread_mutex_lock(&gHostMutex);
    for (UInt32 index = 0; index < count; ++index) {
        if (objectID == kAudioObjectPlugInObject
            && addresses[index].mSelector == kAudioPlugInPropertyDeviceList) {
            ++gDeviceListChanges;
        }
        if (addresses[index].mSelector == kAudioObjectPropertyName) ++gNameChanges;
        if (addresses[index].mSelector == kAudioLevelControlPropertyScalarValue) {
            ++gVolumeChanges;
        }
    }
    pthread_mutex_unlock(&gHostMutex);
    return 0;
}

static int Counter(int* counter) {
    pthread_mutex_lock(&gHostMutex);
    int value = *counter;
    pthread_mutex_unlock(&gHostMutex);
    return value;
}

static OSStatus HostCopyFromStorage(AudioServerPlugInHostRef host, CFStringRef key,
                                    CFPropertyListRef* data) {
    (void)host; (void)key;
    *data = NULL;
    return kAudioHardwareUnknownPropertyError;
}
static OSStatus HostWriteToStorage(AudioServerPlugInHostRef host, CFStringRef key,
                                   CFPropertyListRef data) {
    (void)host; (void)key; (void)data;
    return 0;
}
static OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef host, CFStringRef key) {
    (void)host; (void)key;
    return 0;
}
static OSStatus HostRequestConfigurationChange(AudioServerPlugInHostRef host,
                                               AudioObjectID device, UInt64 action,
                                               void* info) {
    (void)host; (void)device; (void)action; (void)info;
    return 0;
}

static AudioServerPlugInHostInterface gHost = {
    HostPropertiesChanged, HostCopyFromStorage, HostWriteToStorage, HostDeleteFromStorage,
    HostRequestConfigurationChange,
};

static _Atomic UInt64 gFakeNow = 0;
static UInt64 FakeNow(void) { return atomic_load(&gFakeNow); }
static void AdvanceSeconds(double seconds) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double ticks = seconds * 1e9 * timebase.denom / timebase.numer;
    atomic_fetch_add(&gFakeNow, (UInt64)ticks);
}

#pragma mark - Driver calls

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector,
                                          AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return address;
}

static OSStatus Get(AudioObjectID object, AudioObjectPropertySelector selector,
                    AudioObjectPropertyScope scope, UInt32 qualifierSize,
                    const void* qualifier, UInt32 size, void* data, UInt32* outSize) {
    AudioObjectPropertyAddress address = Address(selector, scope);
    UInt32 written = 0;
    OSStatus status = (*gDriver)->GetPropertyData(
        gDriver, object, 0, &address, qualifierSize, qualifier, size, &written, data);
    if (outSize) *outSize = written;
    return status;
}

static UInt32 GetU32(AudioObjectID object, AudioObjectPropertySelector selector,
                     AudioObjectPropertyScope scope) {
    UInt32 value = 0xFFFFFFFF;
    CHECK(Get(object, selector, scope, 0, NULL, sizeof value, &value, NULL) == 0);
    return value;
}

static UInt32 DeviceList(AudioObjectID* devices, UInt32 capacity) {
    UInt32 size = 0;
    AudioObjectPropertyAddress address =
        Address(kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal);
    CHECK((*gDriver)->GetPropertyDataSize(gDriver, kAudioObjectPlugInObject, 0, &address, 0,
                                          NULL, &size) == 0);
    UInt32 written = 0;
    CHECK(Get(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList,
              kAudioObjectPropertyScopeGlobal, 0, NULL, capacity * sizeof(AudioObjectID),
              devices, &written) == 0);
    CHECK(written == size || written == capacity * sizeof(AudioObjectID));
    return written / sizeof(AudioObjectID);
}

static AudioObjectID Translate(const char* uid) {
    CFStringRef string = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectID device = 0xFFFF;
    CHECK(Get(kAudioObjectPlugInObject, kAudioPlugInPropertyTranslateUIDToDevice,
              kAudioObjectPropertyScopeGlobal, sizeof string, &string, sizeof device, &device,
              NULL) == 0);
    CFRelease(string);
    return device;
}

static bool CFStringEquals(CFStringRef string, const char* expected) {
    if (string == NULL) return false;
    char buffer[256];
    bool ok = CFStringGetCString(string, buffer, sizeof buffer, kCFStringEncodingUTF8)
        && strcmp(buffer, expected) == 0;
    return ok;
}

static bool StringProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                           const char* expected) {
    CFStringRef value = NULL;
    if (Get(object, selector, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof value, &value,
            NULL) != 0) {
        return false;
    }
    bool ok = CFStringEquals(value, expected);
    if (value) CFRelease(value);
    return ok;
}

// One registration, as the app sends it.
static OSStatus RegisterDevices(const char* client, int count, const char* const* uids,
                                const char* const* names, SInt32 version) {
    CFMutableArrayRef devices = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (int index = 0; index < count; ++index) {
        CFStringRef uid = CFStringCreateWithCString(NULL, uids[index], kCFStringEncodingUTF8);
        CFStringRef name = CFStringCreateWithCString(NULL, names[index], kCFStringEncodingUTF8);
        SInt32 latencyValue = 7200;
        CFNumberRef latency = CFNumberCreate(NULL, kCFNumberSInt32Type, &latencyValue);
        const void* keys[] = {CFSTR(ESPDISP_AUDIO_KEY_UID), CFSTR(ESPDISP_AUDIO_KEY_NAME),
                              CFSTR(ESPDISP_AUDIO_KEY_LATENCY)};
        const void* values[] = {uid, name, latency};
        CFDictionaryRef entry = CFDictionaryCreate(NULL, keys, values, 3,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(devices, entry);
        CFRelease(entry);
        CFRelease(uid);
        CFRelease(name);
        CFRelease(latency);
    }
    CFNumberRef versionNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &version);
    CFStringRef clientString = CFStringCreateWithCString(NULL, client, kCFStringEncodingUTF8);
    CFStringRef token = CFStringCreateWithCString(NULL, gToken, kCFStringEncodingUTF8);
    const void* keys[] = {CFSTR(ESPDISP_AUDIO_KEY_VERSION), CFSTR(ESPDISP_AUDIO_KEY_CLIENT),
                          CFSTR(ESPDISP_AUDIO_KEY_TOKEN), CFSTR(ESPDISP_AUDIO_KEY_DEVICES)};
    const void* values[] = {versionNumber, clientString, token, devices};
    CFDictionaryRef registration = CFDictionaryCreate(
        NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(token);
    AudioObjectPropertyAddress address =
        Address(ESPDISP_AUDIO_SELECTOR_REGISTER, kAudioObjectPropertyScopeGlobal);
    CFPropertyListRef plist = registration;
    OSStatus status = (*gDriver)->SetPropertyData(gDriver, kAudioObjectPlugInObject, 0,
                                                  &address, 0, NULL, sizeof plist, &plist);
    CFRelease(registration);
    CFRelease(versionNumber);
    CFRelease(clientString);
    CFRelease(devices);
    ESPDisplayAudio_TestReconcileNow();
    return status;
}

static void WriteFrames(AudioObjectID device, AudioObjectID stream, Float64 sampleTime,
                        UInt32 frames, Float32 (*value)(UInt64 frame, int channel)) {
    Float32* buffer = calloc(frames * 2, sizeof(Float32));
    for (UInt32 frame = 0; frame < frames; ++frame) {
        buffer[frame * 2] = value((UInt64)sampleTime + frame, 0);
        buffer[frame * 2 + 1] = value((UInt64)sampleTime + frame, 1);
    }
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof cycle);
    cycle.mOutputTime.mSampleTime = sampleTime;
    cycle.mOutputTime.mFlags = kAudioTimeStampSampleTimeValid;
    CHECK((*gDriver)->DoIOOperation(gDriver, device, stream, 1,
                                    kAudioServerPlugInIOOperationWriteMix, frames, &cycle,
                                    buffer, NULL) == 0);
    free(buffer);
}

static OSStatus ReadAs(AudioObjectID device, const char* token, CFPropertyListRef* data) {
    CFStringRef qualifier = token
        ? CFStringCreateWithCString(NULL, token, kCFStringEncodingUTF8) : NULL;
    OSStatus status = Get(device, ESPDISP_AUDIO_SELECTOR_PCM, kAudioObjectPropertyScopeGlobal,
                          qualifier ? sizeof qualifier : 0, qualifier ? &qualifier : NULL,
                          sizeof *data, data, NULL);
    if (qualifier) CFRelease(qualifier);
    return status;
}

// Reads 'ESpc' with gToken; returns the frame count and hands back the samples.
static UInt32 ReadFrames(AudioObjectID device, Float32** outSamples) {
    CFPropertyListRef data = NULL;
    OSStatus status = ReadAs(device, gToken, &data);
    CHECK(status == 0);
    *outSamples = NULL;
    if (status != 0 || data == NULL) return 0;
    CHECK(CFGetTypeID(data) == CFDataGetTypeID());
    CFIndex length = CFDataGetLength(data);
    CHECK(length % 8 == 0);
    UInt32 frames = (UInt32)(length / 8);
    if (frames) {
        *outSamples = malloc((size_t)length);
        memcpy(*outSamples, CFDataGetBytePtr(data), (size_t)length);
    }
    CFRelease(data);
    return frames;
}

static Float32 Ramp(UInt64 frame, int channel) {
    return (Float32)((frame % 1000) / 1000.0) * (channel ? -1.0f : 1.0f);
}

static Float32 One(UInt64 frame, int channel) {
    (void)frame; (void)channel;
    return 1.0f;
}

#pragma mark - Tests

static AudioObjectID Owned(AudioObjectID device, UInt32 index) {
    AudioObjectID owned[3] = {0, 0, 0};
    UInt32 written = 0;
    CHECK(Get(device, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, 0, NULL,
              sizeof owned, owned, &written) == 0);
    CHECK(written == sizeof owned);
    return owned[index];
}

static void TestFactoryAndInitialize(void) {
    CFUUIDRef wrong = CFUUIDCreateFromString(NULL, CFSTR("00000000-0000-0000-0000-000000000001"));
    CHECK(ESPDisplayAudio_Create(NULL, wrong) == NULL);
    CFRelease(wrong);
    gDriver = ESPDisplayAudio_Create(NULL, kAudioServerPlugInTypeUUID);
    CHECK(gDriver != NULL);

    void* asked = NULL;
    CFUUIDBytes interface = CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID);
    CHECK((*gDriver)->QueryInterface(gDriver, interface, &asked) == S_OK);
    CHECK(asked == gDriver);

    ESPDisplayAudio_TestSetClock(FakeNow);
    atomic_store(&gFakeNow, 1000);
    CHECK((*gDriver)->Initialize(gDriver, &gHost) == 0);

    AudioObjectID devices[8];
    CHECK(DeviceList(devices, 8) == 0);
    CHECK(GetU32(kAudioObjectPlugInObject, kAudioObjectPropertyClass,
                 kAudioObjectPropertyScopeGlobal) == kAudioPlugInClassID);
    CFPropertyListRef version = NULL;
    CHECK(Get(kAudioObjectPlugInObject, ESPDISP_AUDIO_SELECTOR_VERSION,
              kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof version, &version, NULL) == 0);
    SInt32 versionValue = 0;
    CHECK(version != NULL && CFNumberGetValue(version, kCFNumberSInt32Type, &versionValue));
    CHECK(versionValue == ESPDISP_AUDIO_PROTOCOL_VERSION);
    if (version) CFRelease(version);

    AudioServerPlugInCustomPropertyInfo info[2];
    UInt32 written = 0;
    CHECK(Get(kAudioObjectPlugInObject, kAudioObjectPropertyCustomPropertyInfoList,
              kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof info, info, &written) == 0);
    CHECK(written == sizeof info);
    CHECK(info[0].mSelector == ESPDISP_AUDIO_SELECTOR_REGISTER);
    CHECK(info[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
}

static void TestRegistrationIsValidated(void) {
    const char* uids[] = {"uid-a"};
    const char* names[] = {"Display A"};
    CHECK(RegisterDevices("app", 1, uids, names, ESPDISP_AUDIO_PROTOCOL_VERSION + 1)
          == kAudioHardwareUnsupportedOperationError);
    AudioObjectID devices[8];
    CHECK(DeviceList(devices, 8) == 0);

    CFPropertyListRef notADictionary = CFSTR("hello");
    AudioObjectPropertyAddress address =
        Address(ESPDISP_AUDIO_SELECTOR_REGISTER, kAudioObjectPropertyScopeGlobal);
    CHECK((*gDriver)->SetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, 0, NULL,
                                      sizeof notADictionary, &notADictionary)
          == kAudioHardwareIllegalOperationError);
}

static void TestDevicesAppearWithTheirProperties(void) {
    int listChanges = Counter(&gDeviceListChanges);
    const char* uids[] = {"com.espdisplay.display.aabbcc", "com.espdisplay.display.ddeeff"};
    const char* names[] = {"Desk Panel", "Shelf Panel"};
    CHECK(RegisterDevices("app", 2, uids, names, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    CHECK(Counter(&gDeviceListChanges) > listChanges);

    AudioObjectID devices[8];
    CHECK(DeviceList(devices, 8) == 2);
    AudioObjectID desk = Translate(uids[0]);
    CHECK(desk != kAudioObjectUnknown);
    CHECK(Translate("nobody") == kAudioObjectUnknown);
    CHECK(StringProperty(desk, kAudioObjectPropertyName, "Desk Panel"));
    CHECK(StringProperty(desk, kAudioDevicePropertyDeviceUID, uids[0]));
    CHECK(StringProperty(desk, kAudioDevicePropertyModelUID, ESPDISP_AUDIO_MODEL_UID));
    CHECK(GetU32(desk, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal)
          == kAudioDeviceClassID);
    CHECK(GetU32(desk, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                 kAudioObjectPropertyScopeOutput) == 1);
    CHECK(GetU32(desk, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                 kAudioObjectPropertyScopeInput) == 0);
    CHECK(GetU32(desk, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) == 7200);
    CHECK(GetU32(desk, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
          == kAudioDeviceTransportTypeVirtual);

    AudioObjectID stream = 0;
    UInt32 written = 0;
    CHECK(Get(desk, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0, NULL,
              sizeof stream, &stream, &written) == 0);
    CHECK(written == sizeof stream);
    CHECK(Get(desk, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, 0, NULL,
              sizeof stream, &stream, &written) == 0);
    CHECK(written == 0);
    stream = Owned(desk, 0);
    CHECK(GetU32(stream, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 0);
    AudioStreamBasicDescription format;
    CHECK(Get(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0,
              NULL, sizeof format, &format, NULL) == 0);
    CHECK(format.mSampleRate == ESPDISP_AUDIO_SAMPLE_RATE);
    CHECK(format.mChannelsPerFrame == 2);
    CHECK(format.mFormatFlags & kAudioFormatFlagIsFloat);

    AudioObjectID volume = Owned(desk, 1);
    AudioObjectID mute = Owned(desk, 2);
    CHECK(GetU32(volume, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal)
          == kAudioVolumeControlClassID);
    CHECK(GetU32(mute, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal)
          == kAudioMuteControlClassID);
    Boolean settable = false;
    AudioObjectPropertyAddress scalar =
        Address(kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
    CHECK((*gDriver)->IsPropertySettable(gDriver, volume, 0, &scalar, &settable) == 0);
    CHECK(settable);
    AudioObjectPropertyAddress pcm =
        Address(ESPDISP_AUDIO_SELECTOR_PCM, kAudioObjectPropertyScopeGlobal);
    CHECK((*gDriver)->HasProperty(gDriver, desk, 0, &pcm));
    CHECK((*gDriver)->IsPropertySettable(gDriver, desk, 0, &pcm, &settable) == 0);
    CHECK(!settable);

    // The same registration again, a heartbeat, changes nothing.
    listChanges = Counter(&gDeviceListChanges);
    CHECK(RegisterDevices("app", 2, uids, names, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    CHECK(Counter(&gDeviceListChanges) == listChanges);
    CHECK(Translate(uids[0]) == desk);

    // A rename is a name change on the same device, not a new device.
    int nameChanges = Counter(&gNameChanges);
    const char* renamed[] = {"Desk", "Shelf Panel"};
    CHECK(RegisterDevices("app", 2, uids, renamed, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    CHECK(Translate(uids[0]) == desk);
    CHECK(StringProperty(desk, kAudioObjectPropertyName, "Desk"));
    CHECK(Counter(&gNameChanges) == nameChanges + 1);
    CHECK(Counter(&gDeviceListChanges) == listChanges);
}

static void TestMixedAudioIsReadBackOnce(void) {
    AudioObjectID desk = Translate("com.espdisplay.display.aabbcc");
    AudioObjectID stream = Owned(desk, 0);
    CHECK((*gDriver)->StartIO(gDriver, desk, 1) == 0);
    CHECK(GetU32(desk, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal)
          == 1);
    Float64 sampleTime = -1;
    UInt64 hostTime = 0, seed = 0;
    CHECK((*gDriver)->GetZeroTimeStamp(gDriver, desk, 1, &sampleTime, &hostTime, &seed) == 0);
    CHECK(sampleTime == 0);
    CHECK(hostTime > 0);

    Float32* samples = NULL;
    CHECK(ReadFrames(desk, &samples) == 0);
    WriteFrames(desk, stream, 512, 256, Ramp);
    UInt32 frames = ReadFrames(desk, &samples);
    // The first read after start also returns the silence before the first
    // cycle, up to where the HAL began writing.
    CHECK(frames == 768);
    if (frames == 768) {
        CHECK(samples[0] == 0);
        CHECK(samples[511 * 2] == 0);
        bool exact = true;
        for (UInt32 frame = 0; frame < 256; ++frame) {
            exact &= samples[(512 + frame) * 2] == Ramp(512 + frame, 0);
            exact &= samples[(512 + frame) * 2 + 1] == Ramp(512 + frame, 1);
        }
        CHECK(exact);
    }
    free(samples);
    CHECK(ReadFrames(desk, &samples) == 0);

    // A skipped cycle reads as silence, not as a second-old ring.
    WriteFrames(desk, stream, 768 + 48000 - 256, 256, One);
    frames = ReadFrames(desk, &samples);
    CHECK(frames == ESPDISP_AUDIO_MAX_READ_FRAMES);
    if (frames == ESPDISP_AUDIO_MAX_READ_FRAMES) {
        CHECK(samples[0] == 0);
        CHECK(samples[(frames - 1) * 2] == 1.0f);
    }
    free(samples);
}

static void TestVolumeAndMuteScaleWhatIsRead(void) {
    AudioObjectID desk = Translate("com.espdisplay.display.aabbcc");
    AudioObjectID stream = Owned(desk, 0);
    AudioObjectID volume = Owned(desk, 1);
    AudioObjectID mute = Owned(desk, 2);
    AudioObjectPropertyAddress scalar =
        Address(kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
    Float32 half = 0.5f;
    int volumeChanges = Counter(&gVolumeChanges);
    CHECK((*gDriver)->SetPropertyData(gDriver, volume, 0, &scalar, 0, NULL, sizeof half, &half)
          == 0);
    CHECK(Counter(&gVolumeChanges) == volumeChanges + 1);
    Float32 decibels = 0;
    CHECK(Get(volume, kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal,
              0, NULL, sizeof decibels, &decibels, NULL) == 0);
    CHECK(fabsf(decibels - 40.0f * log10f(0.5f)) < 0.01f);

    Float32* samples = NULL;
    (void)ReadFrames(desk, &samples);
    free(samples);
    Float64 time = 100000;
    WriteFrames(desk, stream, time, 64, One);
    // Reading after a jump forward returns the newest frames only.
    UInt32 frames = ReadFrames(desk, &samples);
    CHECK(frames == ESPDISP_AUDIO_MAX_READ_FRAMES);
    if (frames) CHECK(fabsf(samples[(frames - 1) * 2] - 0.25f) < 1e-6f);
    free(samples);

    AudioObjectPropertyAddress value =
        Address(kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
    UInt32 on = 1;
    CHECK((*gDriver)->SetPropertyData(gDriver, mute, 0, &value, 0, NULL, sizeof on, &on) == 0);
    WriteFrames(desk, stream, time + 64, 64, One);
    frames = ReadFrames(desk, &samples);
    CHECK(frames == 64);
    if (frames == 64) CHECK(samples[0] == 0 && samples[127] == 0);
    free(samples);
    UInt32 off = 0;
    CHECK((*gDriver)->SetPropertyData(gDriver, mute, 0, &value, 0, NULL, sizeof off, &off) == 0);
}

typedef struct {
    AudioObjectID device;
    AudioObjectID stream;
    _Atomic bool done;
    UInt64 framesRead;
    bool contiguous;
} RaceState;

static Float32 Index(UInt64 frame, int channel) {
    (void)channel;
    return (Float32)(frame % 4096);
}

static void* Writer(void* context) {
    RaceState* state = context;
    for (UInt64 cycle = 0; cycle < 4000; ++cycle) {
        WriteFrames(state->device, state->stream, (Float64)(cycle * 128), 128, Index);
        // Far faster than real time still, but never a full ring ahead.
        usleep(20);
    }
    atomic_store(&state->done, true);
    return NULL;
}

static void* Reader(void* context) {
    RaceState* state = context;
    Float32 last = -1;
    while (true) {
        bool finished = atomic_load(&state->done);
        Float32* samples = NULL;
        UInt32 frames = ReadFrames(state->device, &samples);
        for (UInt32 frame = 0; frame < frames; ++frame) {
            Float32 value = samples[frame * 2];
            if (last >= 0 && value != fmodf(last + 1, 4096) && frame != 0) {
                state->contiguous = false;
            }
            last = value;
        }
        state->framesRead += frames;
        free(samples);
        if (finished) break;
    }
    return NULL;
}

// The IO thread writes while another thread reads, as in coreaudiod. Under
// TSan this is the check that the ring needs no lock.
static void TestConcurrentWriteAndRead(void) {
    AudioObjectID shelf = Translate("com.espdisplay.display.ddeeff");
    CHECK((*gDriver)->StartIO(gDriver, shelf, 1) == 0);
    RaceState state = {shelf, Owned(shelf, 0), false, 0, true};
    Float32* drained = NULL;
    (void)ReadFrames(shelf, &drained);
    free(drained);
    pthread_t writer, reader;
    pthread_create(&reader, NULL, Reader, &state);
    pthread_create(&writer, NULL, Writer, &state);
    pthread_join(writer, NULL);
    pthread_join(reader, NULL);
    CHECK(state.contiguous);
    CHECK(state.framesRead > 0);
    CHECK((*gDriver)->StopIO(gDriver, shelf, 1) == 0);
}

// Only the client that owns a display may read what the Mac plays to it:
// not a caller without the token, not one with a wrong one, and not another
// client that lists the same UID. Nor can anyone else withdraw it.
static void TestOtherClientsCannotReadOrWithdraw(void) {
    AudioObjectID desk = Translate("com.espdisplay.display.aabbcc");
    CHECK(desk != kAudioObjectUnknown);
    CFPropertyListRef data = NULL;
    CHECK(ReadAs(desk, NULL, &data) == kAudioHardwareIllegalOperationError);
    CHECK(ReadAs(desk, "intruder-token-0123456789abcdef01234", &data)
          == kAudioHardwareIllegalOperationError);
    CHECK(data == NULL);

    const char* app = gToken;
    gToken = "intruder-token-0123456789abcdef01234";
    const char* uids[] = {"com.espdisplay.display.aabbcc"};
    const char* names[] = {"Mine now"};
    CHECK(RegisterDevices("app", 1, uids, names, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    CHECK(ReadAs(desk, gToken, &data) == kAudioHardwareIllegalOperationError);
    CHECK(StringProperty(desk, kAudioObjectPropertyName, "Desk"));
    CHECK(RegisterDevices("app", 0, NULL, NULL, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    // A token too short to be a secret is refused outright.
    gToken = "short";
    CHECK(RegisterDevices("app", 1, uids, names, ESPDISP_AUDIO_PROTOCOL_VERSION)
          == kAudioHardwareIllegalOperationError);
    gToken = app;
    CHECK(Translate("com.espdisplay.display.aabbcc") == desk);
    Float32* samples = NULL;
    (void)ReadFrames(desk, &samples);
    free(samples);
}

static bool Owns(AudioObjectID device, const char* token) {
    CFStringRef qualifier = CFStringCreateWithCString(NULL, token, kCFStringEncodingUTF8);
    CFPropertyListRef value = NULL;
    OSStatus status = Get(device, ESPDISP_AUDIO_SELECTOR_OWNED, kAudioObjectPropertyScopeGlobal,
                          sizeof qualifier, &qualifier, sizeof value, &value, NULL);
    CFRelease(qualifier);
    SInt32 owned = 0;
    CHECK(status == 0 && value != NULL);
    if (value) {
        CFNumberGetValue(value, kCFNumberSInt32Type, &owned);
        CFRelease(value);
    }
    return owned == 1;
}

// A client that fills the device list with made-up UIDs, then lists the
// app's, must neither crowd the app's device out nor end up owning it, even
// from a client slot ahead of the app's.
static void TestCrowdingCannotTakeADevice(void) {
    const char* app = gToken;
    const char* crowder = "crowder-token-0123456789abcdef012345";
    const char* appUIDs[] = {"com.espdisplay.display.aabbcc", "com.espdisplay.display.ddeeff"};
    const char* appNames[] = {"Desk", "Shelf Panel"};
    const char* fakes[] = {"f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8"};
    const char* fakeNames[] = {"x", "x", "x", "x", "x", "x", "x", "x"};
    // The app says goodbye, the crowder takes the first client slot, and the
    // app comes back behind it.
    CHECK(RegisterDevices("app", 0, NULL, NULL, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    gToken = crowder;
    CHECK(RegisterDevices("crowd", 1, fakes, fakeNames, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    gToken = app;
    CHECK(RegisterDevices("app", 2, appUIDs, appNames, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    AudioObjectID desk = Translate(appUIDs[0]);
    CHECK(desk != kAudioObjectUnknown);
    CHECK(Owns(desk, app));

    gToken = crowder;
    CHECK(RegisterDevices("crowd", 8, fakes, fakeNames, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    const char* steal[] = {"com.espdisplay.display.aabbcc"};
    const char* spy[] = {"spy"};
    CHECK(RegisterDevices("crowd", 1, steal, spy, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    gToken = app;
    CHECK(Translate(appUIDs[0]) == desk);
    CHECK(Owns(desk, app));
    CHECK(!Owns(desk, crowder));
    CHECK(StringProperty(desk, kAudioObjectPropertyName, "Desk"));
    CFPropertyListRef data = NULL;
    CHECK(ReadAs(desk, crowder, &data) == kAudioHardwareIllegalOperationError);
    gToken = crowder;
    CHECK(RegisterDevices("crowd", 0, NULL, NULL, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    gToken = app;
}

static void TestClientsUnionAndExpire(void) {
    AudioObjectID desk = Translate("com.espdisplay.display.aabbcc");
    const char* other[] = {"com.espdisplay.display.aabbcc", "com.espdisplay.test.tone"};
    const char* otherNames[] = {"Desk again", "Test Tone"};
    const char* app = gToken;
    gToken = "check-tool-token-0123456789abcdef0123";
    CHECK(RegisterDevices("check-tool", 2, other, otherNames, ESPDISP_AUDIO_PROTOCOL_VERSION)
          == 0);
    // The check tool reads its own device, not the one the app owns.
    CFPropertyListRef data = NULL;
    CHECK(ReadAs(Translate(other[1]), gToken, &data) == 0);
    if (data) CFRelease(data);
    data = NULL;
    CHECK(ReadAs(desk, gToken, &data) == kAudioHardwareIllegalOperationError);
    gToken = app;
    AudioObjectID devices[8];
    CHECK(DeviceList(devices, 8) == 3);
    CHECK(Translate(other[0]) == desk);

    // The app keeps sending its heartbeat; the check tool stops.
    AdvanceSeconds(6);
    const char* uids[] = {"com.espdisplay.display.aabbcc", "com.espdisplay.display.ddeeff"};
    const char* names[] = {"Desk", "Shelf Panel"};
    CHECK(RegisterDevices("app", 2, uids, names, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    AdvanceSeconds(6);
    ESPDisplayAudio_TestReconcileNow();
    CHECK(DeviceList(devices, 8) == 2);
    CHECK(Translate("com.espdisplay.test.tone") == kAudioObjectUnknown);

    // Then the app goes quiet too: every device goes.
    AdvanceSeconds(11);
    ESPDisplayAudio_TestReconcileNow();
    CHECK(DeviceList(devices, 8) == 0);
    UInt32 value = 0;
    CHECK(Get(desk, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, 0, NULL,
              sizeof value, &value, NULL) == kAudioHardwareBadObjectError);
    // The HAL may still stop IO on a device it was just told is gone. The
    // desk is left running here, as if it never did.
    CHECK((*gDriver)->StartIO(gDriver, desk, 1) == 0);

    // Coming back gives a new device ID and keeps the display's volume.
    CHECK(RegisterDevices("app", 2, uids, names, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    AudioObjectID again = Translate(uids[0]);
    CHECK(again != kAudioObjectUnknown && again != desk);
    CHECK(GetU32(again, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal)
          == 0);
    Float32 scalar = 0;
    CHECK(Get(Owned(again, 1), kAudioLevelControlPropertyScalarValue,
              kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof scalar, &scalar, NULL) == 0);
    CHECK(scalar == 0.5f);

    // An empty list says goodbye at once.
    CHECK(RegisterDevices("app", 0, NULL, NULL, ESPDISP_AUDIO_PROTOCOL_VERSION) == 0);
    CHECK(DeviceList(devices, 8) == 0);
}

int main(void) {
    TestFactoryAndInitialize();
    TestRegistrationIsValidated();
    TestDevicesAppearWithTheirProperties();
    TestMixedAudioIsReadBackOnce();
    TestVolumeAndMuteScaleWhatIsRead();
    TestConcurrentWriteAndRead();
    TestOtherClientsCannotReadOrWithdraw();
    TestCrowdingCannotTakeADevice();
    TestClientsUnionAndExpire();
    if (gFailures) {
        fprintf(stderr, "ESPDisplayAudio driver: %d check(s) failed\n", gFailures);
        return 1;
    }
    printf("ESPDisplayAudio driver: all checks passed\n");
    return 0;
}
