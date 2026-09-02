#include "signal_led.h"

#include <WiFi.h>

#include "app_state.h"


// ---- Onboard RGB LED(s): WiFi signal quality indicator ------------------
// WS2812-style addressable LED(s) glowing through the board's acrylic layer,
// on the non-touch board only. Driven as a short strip with every pixel the
// same color: data past the real LED count is ignored, so this works whether
// the board has one LED or several.
//
// Constructed lazily, after detection, and only when the board actually has an
// LED. Adafruit_NeoPixel drives its pin in begin(), and GPIO8's function on the
// Touch board is undocumented - it is measurably not the BOOT button, but that
// is all we know - so a static instance plus an unconditional begin() would
// drive a pin whose other end is a mystery.
const int RGB_COUNT = 8;                // safe upper bound, extras ignored
const uint8_t RGB_LED_BRIGHTNESS = 28;  // subtle glow, not a lamp
uint32_t ledOverrideUntil = 0;          // CFGLED diagnostic hold
Adafruit_NeoPixel *rgbLed = nullptr;
// WiFi signal quality on the RGB LED(s): green is strong, fading through
// yellow and orange to red as RSSI drops; red also means disconnected.
//   >= -55 dBm  green      solid, excellent
//   -55..-90    gradient   green -> yellow -> orange -> red
//   down / < -90  red
void updateSignalLed() {
  if (rgbLed == nullptr) {
    return;  // Touch board: no addressable LED to report signal on
  }
  if (millis() < ledOverrideUntil) {
    return;  // a CFGLED test color is being shown
  }
  uint8_t r, g;
  if (WiFi.status() != WL_CONNECTED) {
    r = 255;
    g = 0;
  } else {
    // Smooth with an EMA: instantaneous RSSI jitters a few dB between
    // reads, which made the color visibly flicker at the band edges.
    static float rssiAvg = 0;
    int rssi = WiFi.RSSI();
    rssiAvg = (rssiAvg == 0) ? rssi : rssiAvg * 0.7f + rssi * 0.3f;
    float clamped = rssiAvg;
    if (clamped > -55) clamped = -55;
    if (clamped < -90) clamped = -90;
    // 0.0 at -90 (red) .. 1.0 at -55 (green)
    float t = (clamped + 90) / 35.0f;
    r = (uint8_t)(255 * (1.0f - t));
    g = (uint8_t)(255 * t);
  }
  rgbLed->fill(rgbLed->Color(r, g, 0));
  rgbLed->show();
}

