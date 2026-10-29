// The contract between ESPDisplayAudio.driver and ESPDisplaySender.
//
// ESPDisplaySender mirrors these values in DisplayAudioDriver.swift, and a
// Swift test reads this file to check the two have not drifted apart.
// Changing any of them is a protocol change: bump the version so an app and a
// driver from different builds refuse each other instead of misreading.

#ifndef ESPDISPLAY_AUDIO_PROTOCOL_H
#define ESPDISPLAY_AUDIO_PROTOCOL_H

#define ESPDISP_AUDIO_PROTOCOL_VERSION 3

// The bundle identifier the app looks the plug-in up by. Production builds
// pass this from ESPDisplay.xcconfig; the fallback keeps standalone host tests
// self-contained.
#ifndef ESPDISP_AUDIO_BUNDLE_ID
#define ESPDISP_AUDIO_BUNDLE_ID "com.resourcefork.espdisplay.audio-driver"
#endif
#define ESPDISP_AUDIO_MODEL_UID ESPDISP_AUDIO_BUNDLE_ID ".display"

// Plug-in object, settable CFDictionary: which displays this client wants a
// device for. Sent again at least every few seconds as a heartbeat; an empty
// device list removes the client at once.
//   { "version": 3, "client": "<name>", "token": "<secret>",
//     "devices": [ { "uid": "...", "name": "...", "latency": <frames> } ] }
// The token is a per-launch secret of at least ESPDISP_AUDIO_MIN_TOKEN_BYTES
// characters. It is the client's identity: the first live client to list a
// UID owns that device, and only its token reads the device's audio. The
// device's own UID, as macOS lists it, is "<uid>.<suffix>": the suffix is the
// first ESPDISP_AUDIO_UID_SUFFIX_BYTES bytes of SHA-256(token) in lowercase
// hex, so a device that changes owner is a different device to macOS.
// Reading it returns { "devices": [ "<device uid>", ... ] }: the UIDs, suffix
// and all, of the devices that exist.
#define ESPDISP_AUDIO_SELECTOR_REGISTER 'ESrg'
// Plug-in object, read-only CFNumber: ESPDISP_AUDIO_PROTOCOL_VERSION.
#define ESPDISP_AUDIO_SELECTOR_VERSION 'ESvr'
// Device object, read-only CFData, qualified by the owner's token as a
// CFString (refused otherwise): every frame mixed for the device since the
// previous read, at most ESPDISP_AUDIO_MAX_READ_FRAMES of the newest, as
// interleaved stereo native-endian Float32 at ESPDISP_AUDIO_SAMPLE_RATE.
// Once macOS stops IO on the device (it is no longer an output in use),
// frames not read within 100 ms are dropped and the read returns none.
#define ESPDISP_AUDIO_SELECTOR_PCM 'ESpc'
// Device object, read-only CFNumber 1 or 0, qualified the same way: whether
// the token owns the device. Takes no frames.
#define ESPDISP_AUDIO_SELECTOR_OWNED 'ESow'

#define ESPDISP_AUDIO_KEY_VERSION "version"
#define ESPDISP_AUDIO_KEY_CLIENT "client"
#define ESPDISP_AUDIO_KEY_TOKEN "token"
#define ESPDISP_AUDIO_KEY_DEVICES "devices"
#define ESPDISP_AUDIO_KEY_UID "uid"
#define ESPDISP_AUDIO_KEY_NAME "name"
#define ESPDISP_AUDIO_KEY_LATENCY "latency"

#define ESPDISP_AUDIO_SAMPLE_RATE 48000
#define ESPDISP_AUDIO_MAX_READ_FRAMES 4800
#define ESPDISP_AUDIO_MAX_DEVICES 8
// Clients registered at once; one more is refused.
#define ESPDISP_AUDIO_MAX_CLIENTS 8
#define ESPDISP_AUDIO_CLIENT_TIMEOUT_SECONDS 10
#define ESPDISP_AUDIO_MIN_TOKEN_BYTES 32
#define ESPDISP_AUDIO_UID_SUFFIX_BYTES 8

#endif
