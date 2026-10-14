// Loads a built ESPDisplayAudio.driver the way coreaudiod finds a HAL
// plug-in: through CFPlugIn, by the AudioServerPlugIn type its Info.plist
// declares, then through the driver interface. Catches a factory name, UUID
// or export that does not match, which the source-level test cannot see.

#include <CoreAudio/AudioServerPlugIn.h>
#include <stdio.h>
#include <string.h>

#include "../ESPDisplayAudioProtocol.h"

static OSStatus PropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object,
                                  UInt32 count, const AudioObjectPropertyAddress* addresses) {
    (void)host; (void)object; (void)count; (void)addresses;
    return 0;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <path to ESPDisplayAudio.driver>\n", argv[0]);
        return 2;
    }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        NULL, (const UInt8*)argv[1], (CFIndex)strlen(argv[1]), true);
    CFPlugInRef plugIn = CFPlugInCreate(NULL, url);
    CFRelease(url);
    if (plugIn == NULL) {
        fprintf(stderr, "bundle load: CFPlugInCreate failed\n");
        return 1;
    }
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(
        kAudioServerPlugInTypeUUID, plugIn);
    if (factories == NULL || CFArrayGetCount(factories) != 1) {
        fprintf(stderr, "bundle load: expected one AudioServerPlugIn factory\n");
        return 1;
    }
    CFUUIDRef factory = CFArrayGetValueAtIndex(factories, 0);
    IUnknownVTbl** unknown = CFPlugInInstanceCreate(NULL, factory, kAudioServerPlugInTypeUUID);
    CFRelease(factories);
    if (unknown == NULL) {
        fprintf(stderr, "bundle load: the factory returned nothing\n");
        return 1;
    }
    AudioServerPlugInDriverRef driver = NULL;
    if ((*unknown)->QueryInterface(unknown,
                                   CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID),
                                   (LPVOID*)&driver) != S_OK || driver == NULL) {
        fprintf(stderr, "bundle load: no driver interface\n");
        return 1;
    }
    AudioServerPlugInHostInterface hostInterface = {PropertiesChanged, NULL, NULL, NULL, NULL};
    AudioServerPlugInHostRef host = &hostInterface;
    if ((*driver)->Initialize(driver, host) != 0) {
        fprintf(stderr, "bundle load: Initialize failed\n");
        return 1;
    }
    AudioObjectPropertyAddress address = {ESPDISP_AUDIO_SELECTOR_VERSION,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    CFPropertyListRef version = NULL;
    UInt32 size = 0;
    SInt32 value = 0;
    if ((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &address, 0, NULL,
                                   sizeof version, &size, &version) != 0
        || version == NULL || !CFNumberGetValue(version, kCFNumberSInt32Type, &value)
        || value != ESPDISP_AUDIO_PROTOCOL_VERSION) {
        fprintf(stderr, "bundle load: protocol version did not read back\n");
        return 1;
    }
    CFRelease(version);
    printf("ESPDisplayAudio bundle load: factory, interface and version %d found\n", (int)value);
    return 0;
}
