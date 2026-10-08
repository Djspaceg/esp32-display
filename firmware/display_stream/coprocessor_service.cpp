#include "coprocessor_service.h"

#include <Arduino.h>

#if defined(CONFIG_ESP_HOSTED_ENABLED)
#include <WiFi.h>

#include "coprocessor_ota.h"
#include "esp32-hal-hosted.h"
#endif

namespace coprocessorsvc {

#if defined(CONFIG_ESP_HOSTED_ENABLED)

static coprocessor::Status probed = coprocessor::Status::Unknown;
static uint32_t hostVersion = 0;
static uint32_t coprocessorVersion = 0;

static void versionText(uint32_t packed, char *out, size_t len) {
  snprintf(out, len, "%lu.%lu.%lu", (unsigned long)(packed >> 16),
           (unsigned long)((packed >> 8) & 0xff),
           (unsigned long)(packed & 0xff));
}

void probe() {
  // Both getters read structs the core filled in; neither is an RPC.
  uint32_t major = 0, minor = 0, patch = 0;
  hostedGetHostVersion(&major, &minor, &patch);
  hostVersion = coprocessor::version(major, minor, patch);
  char host[16];
  versionText(hostVersion, host, sizeof(host));
  if (!hostedIsInitialized()) {
    // No link at all: that is not evidence of an old coprocessor.
    probed = coprocessor::Status::Unknown;
    Serial.printf("WiFi: C6 coprocessor link is not up; its ESP-Hosted "
                  "version is unknown (host %s)\n", host);
    return;
  }
  // The core's hostedHasUpdate() at ESP-Hosted init leaves 0.0.0 here when
  // Req_GetCoprocessorFwVersion went unanswered.
  hostedGetSlaveVersion(&major, &minor, &patch);
  coprocessorVersion = coprocessor::version(major, minor, patch);
  probed = coprocessor::classify(hostVersion, coprocessorVersion != 0,
                                 coprocessorVersion);
  char cp[16];
  coprocessorVersionText(cp, sizeof(cp));
  if (coprocessor::needsUpdate(probed)) {
    Serial.printf(
        "WiFi: C6 coprocessor ESP-Hosted %s is older than the host's %s; "
        "outgoing WiFi can stop while the link stays up. %s\n",
        coprocessorVersion == 0 ? "(unreported)" : cp, host,
        coprocessor::imageForHost(hostVersion) != nullptr
            ? "Update it over USB with CFGC6UPDATE."
            : "No coprocessor image is pinned for this host.");
  } else {
    Serial.printf("WiFi: C6 coprocessor ESP-Hosted %s, host %s (%s)\n", cp,
                  host, coprocessor::statusToken(probed));
  }
}

coprocessor::Status status() { return probed; }

void coprocessorVersionText(char *out, size_t len) {
  if (coprocessorVersion == 0) {
    snprintf(out, len, "none");
    return;
  }
  versionText(coprocessorVersion, out, len);
}

const char *startUpdate() {
  if (coprocessorota::running()) return "an update is already running";
  if (!coprocessor::needsUpdate(probed)) {
    return probed == coprocessor::Status::Unknown
               ? "coprocessor version not known"
               : "coprocessor is not older than the host";
  }
  const coprocessor::Image *image = coprocessor::imageForHost(hostVersion);
  if (image == nullptr) return "no coprocessor image is pinned for this host";
  if (WiFi.status() != WL_CONNECTED) return "WiFi is not connected";
  return coprocessorota::start(*image, hostVersion);
}

#else

void probe() {}
coprocessor::Status status() { return coprocessor::Status::Unknown; }
void coprocessorVersionText(char *out, size_t len) {
  if (len > 0) out[0] = 0;
}
const char *startUpdate() { return "this board has no hosted coprocessor"; }

#endif

}  // namespace coprocessorsvc
