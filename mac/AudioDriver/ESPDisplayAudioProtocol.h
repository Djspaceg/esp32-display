// The contract between ESPDisplayAudio.driver and ESPDisplaySender.
//
// ESPDisplaySender mirrors these values in DisplayAudioDriver.swift, and a
// Swift test reads this file to check the two have not drifted apart.
// Changing any of them is a protocol change: bump the version so an app and a
// driver from different builds refuse each other instead of misreading.

#ifndef ESPDISPLAY_AUDIO_PROTOCOL_H
#define ESPDISPLAY_AUDIO_PROTOCOL_H

#define ESPDISP_AUDIO_PROTOCOL_VERSION 1

// The bundle identifier the app looks the plug-in up by.
#define ESPDISP_AUDIO_BUNDLE_ID "com.espdisplay.audio-driver"
#define ESPDISP_AUDIO_MODEL_UID "com.espdisplay.audio-driver.display"

// Plug-in object, settable CFDictionary: which displays this client wants a
// device for. Sent again at least every few seconds as a heartbeat; an empty
// device list removes the client at once.
//   { "version": 1, "client": "<id>",
//     "devices": [ { "uid": "...", "name": "...", "latency": <frames> } ] }
// Reading it returns { "devices": [ "<uid>", ... ] } for the devices that exist.
#define ESPDISP_AUDIO_SELECTOR_REGISTER 'ESrg'
// Plug-in object, read-only CFNumber: ESPDISP_AUDIO_PROTOCOL_VERSION.
#define ESPDISP_AUDIO_SELECTOR_VERSION 'ESvr'
// Device object, read-only CFData: every frame mixed for the device since the
// previous read, at most ESPDISP_AUDIO_MAX_READ_FRAMES of the newest, as
// interleaved stereo native-endian Float32 at ESPDISP_AUDIO_SAMPLE_RATE.
#define ESPDISP_AUDIO_SELECTOR_PCM 'ESpc'

#define ESPDISP_AUDIO_KEY_VERSION "version"
#define ESPDISP_AUDIO_KEY_CLIENT "client"
#define ESPDISP_AUDIO_KEY_DEVICES "devices"
#define ESPDISP_AUDIO_KEY_UID "uid"
#define ESPDISP_AUDIO_KEY_NAME "name"
#define ESPDISP_AUDIO_KEY_LATENCY "latency"

#define ESPDISP_AUDIO_SAMPLE_RATE 48000
#define ESPDISP_AUDIO_MAX_READ_FRAMES 4800
#define ESPDISP_AUDIO_MAX_DEVICES 8
#define ESPDISP_AUDIO_CLIENT_TIMEOUT_SECONDS 10

#endif
