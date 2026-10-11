// On-device screens: the idle/status card, signal survey, WiFi preset selector,
// boot-mode menu, quick info bar, and OTA progress screen. All draw through
// bufB while bufA remains the network path's always-current framebuffer.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "boot_menu.h"  // whether this image has a boot menu to draw

// Idle/status card (composed over the last frame; repositions against
// burn-in).
void drawIdleScreen();

// WiFi status screen (the signal survey): a live full-brightness RSSI meter
// with the network, address, name, firmware and battery under it (a BOOT
// press or a tap on the idle card).
void drawSurveyScreen();
bool handleSurveyTap(int16_t x, int16_t y);

// Saved WiFi preset selector. Entered by a BOOT double press, through the
// visible survey button, or by holding BOOT/touch on the survey. While active it owns the panel; streaming continues to
// fill bufA but cannot overwrite the selector.
extern bool wifiSelectorActive;
void openWifiSelector();
void closeWifiSelector();
void moveWifiSelector(int direction);
void activateWifiSelector();
void drawWifiSelectorScreen();
void handleWifiSelectorTap(int16_t x, int16_t y);
// Called every loop pass: on glass with no touch, closes a selector left idle
// (it has no BACK control there).
void serviceWifiSelectorTimeout();

// Boot-mode menu screen (state and input live in boot_menu.cpp, which also
// decides whether this image has a menu at all). labels has count entries;
// row 0 is the default and is marked as such.
#if defined(ESPDISP_BOOT_MENU_RUNTIME)
void drawBootMenuScreen(const char *const *labels, size_t count,
                        size_t selected, const char *title,
                        const char *message);
#endif

// Quick info bar: a status line across the top of a lit panel for a couple
// of seconds after a plain tap. The row range it currently covers is public
// so the draw pass can redraw the bar over runs that overwrite its rows.
extern int infoBarY0;
extern int infoBarY1;
bool infoBarActive();
const char *defaultInfoBarText();
void showInfoBar(const char *text);
void clearInfoBarIfExpired();
void redrawInfoBarOverRun();

// A small square at a mapped touch point, for CFGTOUCHLOG. Left for the next
// redraw to erase: a streamed frame that changes there, or within 500 ms on the
// survey card, which refreshes itself.
void drawTouchMarker(int16_t x, int16_t y);

// OTA progress screen (percent < 0 draws no bar).
void drawOtaScreen(const char *headline, int percent);
