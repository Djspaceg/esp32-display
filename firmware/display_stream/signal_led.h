// The addressable RGB LED (non-touch C6 board only): WiFi signal quality
// color, with identify and CFGLED overrides.
#pragma once

#include <Adafruit_NeoPixel.h>

#include <stdint.h>

extern const int RGB_COUNT;
extern const uint8_t RGB_LED_BRIGHTNESS;
extern uint32_t ledOverrideUntil;  // CFGLED / identify diagnostic hold
extern Adafruit_NeoPixel *rgbLed;  // nullptr on boards without an LED

void updateSignalLed();
