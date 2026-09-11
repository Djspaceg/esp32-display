// On-device screens: the idle/status card, signal survey, WiFi preset selector,
// quick info bar, and OTA progress screen. All draw through bufB while bufA
// remains the network path's always-current framebuffer.
#pragma once

// Idle/status card (composed over the last frame; repositions against
// burn-in).
void drawIdleScreen();

// Signal survey: a live full-brightness RSSI meter (BOOT double-press or a
// tap on the idle card).
void drawSurveyScreen();

// Saved WiFi preset selector. Entered by holding BOOT (or touch) from the
// signal survey. While active it owns the panel; streaming continues to fill
// bufA but cannot overwrite the selector.
extern bool wifiSelectorActive;
void openWifiSelector();
void closeWifiSelector();
void moveWifiSelector(int direction);
void activateWifiSelector();
void drawWifiSelectorScreen();

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

// OTA progress screen (percent < 0 draws no bar).
void drawOtaScreen(const char *headline, int percent);
