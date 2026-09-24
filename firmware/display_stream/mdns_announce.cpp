#include "mdns_announce.h"

#include <Arduino.h>
#include <ESPmDNS.h>
#include <WiFi.h>

#include "app_state.h"
#include "audio_protocol.h"
#include "device_protocol.h"
#include "ota_service.h"
#include "telemetry.h"


// Advertise the service and every TXT record. Both the initial announce and
// the post-heal re-announce call this, and every value is derived from the
// constant it describes - the previous copies hardcoded "caps" and "res" in
// two places, so adding a capability would have silently left the advertised
// value stale.
void addMdnsService() {
  char capsBuf[9], resBuf[16], protoBuf[4], audioPortBuf[6],
      audioVersionBuf[4], audioRateBuf[7], audioPlaybackChannelsBuf[4],
      audioCaptureChannelsBuf[4];
  const board::AudioConfig *audio =
      board::generatedAudioConfig(boardVariant);
  snprintf(capsBuf, sizeof(capsBuf), "%08lx", (unsigned long)deviceCapabilities());
  snprintf(resBuf, sizeof(resBuf), "%ux%u", (unsigned)PANEL_W, (unsigned)PANEL_H);
  snprintf(protoBuf, sizeof(protoBuf), "%u",
           (unsigned)deviceproto::FRAME_PROTOCOL_VERSION);
  snprintf(audioPortBuf, sizeof(audioPortBuf), "%u",
           (unsigned)audioproto::UDP_PORT);
  snprintf(audioVersionBuf, sizeof(audioVersionBuf), "%u",
           (unsigned)audioproto::VERSION);
  snprintf(audioRateBuf, sizeof(audioRateBuf), "%lu",
           audio == nullptr ? 0UL : (unsigned long)audio->playbackRateHz);
  snprintf(audioPlaybackChannelsBuf, sizeof(audioPlaybackChannelsBuf), "%u",
           audio == nullptr ? 0U : (unsigned)audio->playbackChannels);
  snprintf(audioCaptureChannelsBuf, sizeof(audioCaptureChannelsBuf), "%u",
           audio == nullptr ? 0U : (unsigned)audio->captureChannels);
  // Bind as const char *: ESPmDNS overloads addServiceTxt on char *,
  // const char *, and String, and a mutable buffer makes all three viable
  // under the -fpermissive the Arduino build uses, which is ambiguous.
  //
  // chip is already a const char * from chip_identity.h, and is bound here with
  // the others so the whole record set reads as one list. It says which of a
  // firmware bundle's images belongs to this panel; see chip_identity.h for why
  // that is advertised instead of inferred from res. UNVERIFIED that a browser
  // sees it - no board is attached, so this rests on it being the same call the
  // records beside it go through, not on an observation.
  const char *caps = capsBuf, *res = resBuf, *proto = protoBuf;
  const char *audioPort = audioPortBuf;
  const char *audioVersion = audioVersionBuf;
  const char *audioRate = audioRateBuf;
  const char *audioPlaybackChannels = audioPlaybackChannelsBuf;
  const char *audioCaptureChannels = audioCaptureChannelsBuf;
  const char *chip = bcfg->platform->chipToken;
  const char *target = board::targetToken(boardVariant);
  const char *profile = board::variantToken(boardVariant);
  const char *partition = bcfg->platform->partitionToken;
  MDNS.setInstanceName(cfgName);
  MDNS.addService("espdisp", "udp", UDP_PORT);
  MDNS.addServiceTxt("espdisp", "udp", "name", cfgName);
  MDNS.addServiceTxt("espdisp", "udp", "res", res);
  MDNS.addServiceTxt("espdisp", "udp", "fw", FW_VERSION);
  MDNS.addServiceTxt("espdisp", "udp", "proto", proto);
  MDNS.addServiceTxt("espdisp", "udp", "caps", caps);
  MDNS.addServiceTxt("espdisp", "udp", "chip", chip);
  MDNS.addServiceTxt("espdisp", "udp", "target", target);
  MDNS.addServiceTxt("espdisp", "udp", "profile", profile);
  MDNS.addServiceTxt("espdisp", "udp", "partition", partition);
  if (audioAvailable && audio != nullptr) {
    MDNS.addServiceTxt("espdisp", "udp", "audio-port", audioPort);
    MDNS.addServiceTxt("espdisp", "udp", "audio-version", audioVersion);
    MDNS.addServiceTxt("espdisp", "udp", "audio-rate", audioRate);
    MDNS.addServiceTxt("espdisp", "udp", "audio-play-ch",
                       audioPlaybackChannels);
    MDNS.addServiceTxt("espdisp", "udp", "audio-capture-ch",
                       audioCaptureChannels);
    MDNS.addService("espdisp-audio", "udp", audioproto::UDP_PORT);
  }
  if (otaActive) {
    // _arduino._tcp is what espota/arduino-cli browse for. It is registered from
    // here rather than by ArduinoOTA itself (which is why setupOta calls
    // setMdnsEnabled(false)) for two reasons, both read out of the core's
    // ArduinoOTA.cpp: its begin() would call MDNS.begin() a second time, and its
    // end() calls MDNS.end(), i.e. mdns_free(), which would take _espdisp._udp
    // down with it. Registering here also means the WiFi-heal path gets OTA back
    // for free - that path tears mDNS down and calls this function again, so
    // without this line OTA would silently stop being discoverable after the
    // first heal.
    MDNS.enableArduino(OTA_PORT, true /* auth required */);
    // `enableArduino` supplies chip-level board metadata. Add the independent
    // family, runtime profile, and partition evidence used by update tooling.
    MDNS.addServiceTxt("arduino", "tcp", "target", target);
    MDNS.addServiceTxt("arduino", "tcp", "profile", profile);
    MDNS.addServiceTxt("arduino", "tcp", "partition", partition);
  }
}
bool restartMdnsService() {
  MDNS.end();
  if (!MDNS.begin(cfgName.c_str())) {
    Serial.println("WARN: mDNS failed to restart after WiFi reconnect");
    return false;
  }
  addMdnsService();
  Serial.printf("mDNS re-announced, IP %s\n", WiFi.localIP().toString().c_str());
  return true;
}
