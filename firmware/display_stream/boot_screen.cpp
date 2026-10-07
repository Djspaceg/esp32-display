#include "boot_screen.h"

#include <Arduino.h>
#include <esp_heap_caps.h>
#include <string.h>

#include "app_state.h"
#include "dma_gate.h"
#include "orientation.h"
#include "panel_transfer.h"

namespace bootscreen {

namespace {

using bootscreenmodel::Layout;

Stage stage = Stage::Starting;
uint16_t permille = bootscreenmodel::viewFor(Stage::Starting).permille;
char failedText[bootscreenmodel::MAX_STATUS_CHARS + 1] = {0};
bool drawn = false;
bool released = false;
// A transfer of ours that never completed: the panel may still be reading a
// strip, so nothing more is drawn rather than stalling every repaint.
bool stalled = false;
// What is on the panel, so advance() repaints only what changed.
Layout shown = {};
const char *shownText = nullptr;
int shownFill = -1;
uint16_t shownColor = 0;

// Each strip is at most this many bytes; two of them alternate so one is
// composed while the other is on its way to the panel. Internal DMA-capable
// RAM, because C6 and C3 panels read the source directly. Taken for one draw
// and given back, so the frame buffers allocated after the first draw find
// the heap as they always have.
constexpr size_t STRIP_BYTES = 8192;

const char *currentText() {
  return stage == Stage::Failed ? failedText
                                : bootscreenmodel::viewFor(stage).text;
}

uint16_t currentColor() { return bootscreenmodel::viewFor(stage).barColor; }

Layout currentLayout() {
  return bootscreenmodel::layout(PANEL_GEOMETRY.frameWidth(panelLandscape),
                                 PANEL_GEOMETRY.frameHeight(panelLandscape),
                                 bcfg->panel->roundDisplay);
}

bool sameShape(const Layout &a, const Layout &b) {
  return a.width == b.width && a.height == b.height;
}

// The transfer of one strip takes well under a millisecond, and
// waitForDmaIdle() sleeps in 2 ms steps: across the hundreds of strips of a
// large panel that sleeping was most of the draw. Spin briefly first.
bool stripsIdle() {
  const uint32_t started = micros();
  while (dmaInFlight != 0) {
    if ((uint32_t)(micros() - started) > 5000) return waitForDmaIdle(500);
  }
  return true;
}

// Composes and queues rows [y0, y1) in strips.
bool pushRows(const Layout &l, int y0, int y1) {
  if (panel == nullptr || bcfg == nullptr || stalled) return false;
  // A transfer already stuck before this draw: give up before taking memory,
  // and for good, so later repaints do not each wait on it again.
  if (!stripsIdle()) {
    stalled = true;
    Serial.println("boot screen: panel busy; no further repaints");
    return false;
  }
  if (y0 < 0) y0 = 0;
  if (y1 > l.height) y1 = l.height;
  if (y1 <= y0) return true;
  const size_t rowBytes = (size_t)l.width * 2;
  int stripRows = (int)(STRIP_BYTES / rowBytes);
  if (stripRows < 1) stripRows = 1;
  if (stripRows > y1 - y0) stripRows = y1 - y0;
  const size_t stripBytes = (size_t)stripRows * rowBytes;
  const uint32_t caps = MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
  uint8_t *strips[2] = {(uint8_t *)heap_caps_malloc(stripBytes, caps), nullptr};
  if (strips[0] == nullptr) {
    Serial.printf("boot screen: no %u B strip buffer\n", (unsigned)stripBytes);
    return false;
  }
  if (y1 - y0 > stripRows) {
    strips[1] = (uint8_t *)heap_caps_malloc(stripBytes, caps);
  }
  const char *text = currentText();
  const uint16_t color = currentColor();
  bool ok = true;
  int k = 0;
  for (int y = y0; y < y1 && ok; y += stripRows) {
    const int rows = y1 - y < stripRows ? y1 - y : stripRows;
    // With one buffer, the previous strip must be off it before it is reused.
    if (strips[1] == nullptr && !stripsIdle()) {
      ok = false;
      break;
    }
    bootscreenmodel::composeRows(strips[k], l, text, permille, color, y, rows);
    if (!stripsIdle()) {
      ok = false;
      break;
    }
    if (queuePanelBitmap(panel, *bcfg, 0, y, l.width, y + rows, strips[k]) !=
        ESP_OK) {
      statDrawErrors = statDrawErrors + 1;
      ok = false;
      break;
    }
    if (strips[1] != nullptr) k ^= 1;
  }
  // A transfer still in flight may be reading a strip, so a strip is only
  // freed once the panel is idle. After a stall it is left allocated: losing
  // 16 KB beats the panel reading freed memory.
  if (stripsIdle()) {
    heap_caps_free(strips[0]);
    heap_caps_free(strips[1]);
  } else {
    stalled = true;
    ok = false;
    Serial.println("boot screen: panel transfer stalled; no further repaints");
  }
  return ok;
}

void remember(const Layout &l) {
  shown = l;
  shownText = currentText();
  shownFill = bootscreenmodel::barFill(l, permille);
  shownColor = currentColor();
}

void logStage() {
  Serial.printf("boot screen: %s (%u%%) at %lu ms\n", currentText(),
                (unsigned)(permille / 10), (unsigned long)millis());
}

bool drawAll(const Layout &l) {
  const bool ok = pushRows(l, 0, l.height);
  drawn = true;
  released = false;
  remember(l);
  return ok;
}

// Repaints what differs from what is on the panel.
void repaint() {
  const Layout l = currentLayout();
  if (!drawn || released || !sameShape(l, shown)) {
    drawAll(l);
    return;
  }
  int y0, y1;
  if (shownText != currentText()) {
    bootscreenmodel::textRows(l, y0, y1);
    pushRows(l, y0, y1);
  }
  const int fill = bootscreenmodel::barFill(l, permille);
  if (fill != shownFill || shownColor != currentColor()) {
    bootscreenmodel::barRows(l, y0, y1);
    pushRows(l, y0, y1);
  }
  remember(l);
}

}  // namespace

bool show(Stage next) {
  // Redrawing the current stage keeps how far the WiFi join's bar has got.
  if (next != stage) permille = bootscreenmodel::viewFor(next).permille;
  stage = next;
  const bool ok = drawAll(currentLayout());
  logStage();
  return ok;
}

void advance(Stage next) {
  if (next == stage && next != Stage::Failed) return;
  stage = next;
  permille = bootscreenmodel::viewFor(next).permille;
  repaint();
  logStage();
}

void joining(uint32_t elapsedMs, uint32_t timeoutMs) {
  if (stage != Stage::JoiningWifi) {
    advance(Stage::JoiningWifi);
  }
  permille = bootscreenmodel::joiningPermille(elapsedMs, timeoutMs);
  if (released) return;
  const Layout l = currentLayout();
  if (bootscreenmodel::barFill(l, permille) != shownFill) repaint();
}

void fail(const char *text) {
  strncpy(failedText, text, sizeof(failedText) - 1);
  failedText[sizeof(failedText) - 1] = 0;
  // A new string address each time is not guaranteed, so force the text
  // repaint rather than compare pointers.
  shownText = nullptr;
  advance(Stage::Failed);
}

void redraw() { show(stage); }

void release() { released = true; }

bool showing() {
  return drawn && !released && statFramesShown == 0 && statFramesPartial == 0;
}

bool composeRows(uint8_t *dst, int width, int y0, int y1) {
  if (!showing()) return false;
  const Layout l = currentLayout();
  if (l.width != width || y0 < 0 || y1 > l.height || y1 <= y0) return false;
  bootscreenmodel::composeRows(dst, l, currentText(), permille, currentColor(),
                               y0, y1 - y0);
  return true;
}

}  // namespace bootscreen
