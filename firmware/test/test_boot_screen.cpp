// Host tests for the boot screen (firmware/display_stream/boot_screen_model.h)
// and its image asset (boot_image.h), on every board profile in both of its
// frame shapes.
//
// With BOOT_SCREEN_PREVIEW_DIR set, also writes one PPM per profile and shape
// of the screen mid-way through the WiFi join, for looking at.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <board_config.h>

#include "../display_stream/boot_screen_model.h"

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      return 1;                                              \
    }                                                        \
  } while (0)

using bootscreenmodel::Layout;
using bootscreenmodel::Stage;

static const Stage ALL_STAGES[] = {
    Stage::Starting, Stage::Preparing, Stage::Sensors,  Stage::WifiLink,
    Stage::JoiningWifi, Stage::Audio,  Stage::Services, Stage::Ready,
    Stage::NoWifi,   Stage::Failed,
};

static uint16_t pixelAt(const std::vector<uint8_t> &screen, int width, int x,
                        int y) {
  const size_t at = ((size_t)y * width + x) * 2;
  return (uint16_t)((screen[at] << 8) | screen[at + 1]);
}

static std::vector<uint8_t> compose(const Layout &l, const char *text,
                                    uint16_t permille, uint16_t color) {
  std::vector<uint8_t> screen((size_t)l.width * l.height * 2);
  bootscreenmodel::composeRows(screen.data(), l, text, permille, color, 0,
                               l.height);
  return screen;
}

// The asset pixel at image coordinates, or BACKGROUND where none is stored.
static uint16_t imagePixel(int x, int y) {
  for (uint16_t i = bootimage::ROW_RUNS[y]; i < bootimage::ROW_RUNS[y + 1];
       ++i) {
    const bootimage::Run &run = bootimage::RUNS[i];
    if (x >= run.x && x < run.x + run.length) {
      return bootimage::PIXELS[run.pixel + (x - run.x)];
    }
  }
  return bootimage::BACKGROUND;
}

// Every corner of a box is on the glass.
static bool onGlass(const Layout &l, int x0, int y0, int x1, int y1) {
  if (x0 < 0 || y0 < 0 || x1 > l.width || y1 > l.height) return false;
  if (!l.round) return true;
  const int xs[2] = {x0, x1};
  const int ys[2] = {y0, y1};
  for (int x : xs) {
    for (int y : ys) {
      const long dx = 2L * x - l.width;
      const long dy = 2L * y - l.height;
      if (dx * dx + dy * dy > (long)l.width * l.width) return false;
    }
  }
  return true;
}

static void writePreview(const char *dir, const std::string &name,
                         const Layout &l, const std::vector<uint8_t> &screen) {
  const std::string path = std::string(dir) + "/" + name + ".ppm";
  FILE *f = fopen(path.c_str(), "wb");
  if (f == nullptr) return;
  fprintf(f, "P6\n%d %d\n255\n", l.width, l.height);
  for (int y = 0; y < l.height; ++y) {
    for (int x = 0; x < l.width; ++x) {
      uint16_t c = pixelAt(screen, l.width, x, y);
      if (l.round) {
        const long dx = 2L * x + 1 - l.width, dy = 2L * y + 1 - l.height;
        if (dx * dx + dy * dy > (long)l.width * l.width) c = 0;  // bezel
      }
      const uint8_t r = (uint8_t)(((c >> 11) & 0x1F) * 255 / 31);
      const uint8_t g = (uint8_t)(((c >> 5) & 0x3F) * 255 / 63);
      const uint8_t b = (uint8_t)((c & 0x1F) * 255 / 31);
      fputc(r, f);
      fputc(g, f);
      fputc(b, f);
    }
  }
  fclose(f);
}

int main() {
  // --- The asset is well formed ---------------------------------------------
  {
    CHECK(bootimage::WIDTH == 120 && bootimage::HEIGHT == 120);
    CHECK(bootimage::ROW_RUNS[0] == 0);
    const size_t runCount = sizeof(bootimage::RUNS) / sizeof(bootimage::RUNS[0]);
    const size_t pixelCount =
        sizeof(bootimage::PIXELS) / sizeof(bootimage::PIXELS[0]);
    CHECK(bootimage::ROW_RUNS[bootimage::HEIGHT] == runCount);
    uint32_t next = 0;
    for (int y = 0; y < bootimage::HEIGHT; ++y) {
      CHECK(bootimage::ROW_RUNS[y] <= bootimage::ROW_RUNS[y + 1]);
      int lastEnd = -1;
      for (uint16_t i = bootimage::ROW_RUNS[y]; i < bootimage::ROW_RUNS[y + 1];
           ++i) {
        const bootimage::Run &run = bootimage::RUNS[i];
        CHECK(run.length > 0);
        CHECK((int)run.x > lastEnd);
        CHECK(run.x + run.length <= bootimage::WIDTH);
        CHECK(run.pixel == next);
        next += run.length;
        lastEnd = run.x + run.length;
      }
    }
    CHECK(next == pixelCount);
    // A cut-out, not a rectangle: some of it is background.
    CHECK(pixelCount < (size_t)bootimage::WIDTH * bootimage::HEIGHT);
  }

  // --- Stage text and progress ----------------------------------------------
  {
    uint16_t previous = 0;
    for (Stage stage : ALL_STAGES) {
      const bootscreenmodel::StageView view = bootscreenmodel::viewFor(stage);
      CHECK(strlen(view.text) > 0);
      CHECK(strlen(view.text) <= bootscreenmodel::MAX_STATUS_CHARS);
      CHECK(view.permille <= 1000);
      CHECK(view.permille >= previous);  // the bar never runs backwards
      previous = view.permille;
    }
    CHECK(strcmp(bootscreenmodel::viewFor(Stage::Starting).text, "starting") == 0);
    CHECK(strcmp(bootscreenmodel::viewFor(Stage::JoiningWifi).text,
                 "joining WiFi") == 0);
    CHECK(strcmp(bootscreenmodel::viewFor(Stage::Ready).text, "ready") == 0);
    CHECK(strlen("memory error") <= bootscreenmodel::MAX_STATUS_CHARS);
    CHECK(strlen("start failed") <= bootscreenmodel::MAX_STATUS_CHARS);
    const uint16_t joinStart = bootscreenmodel::viewFor(Stage::JoiningWifi).permille;
    const uint16_t audio = bootscreenmodel::viewFor(Stage::Audio).permille;
    CHECK(bootscreenmodel::joiningPermille(0, 30000) == joinStart);
    CHECK(bootscreenmodel::joiningPermille(15000, 30000) > joinStart);
    CHECK(bootscreenmodel::joiningPermille(30000, 30000) < audio);
    CHECK(bootscreenmodel::joiningPermille(90000, 30000) < audio);
    CHECK(bootscreenmodel::joiningPermille(5, 0) < audio);
    uint16_t last = 0;
    for (uint32_t t = 0; t <= 31000; t += 100) {
      const uint16_t p = bootscreenmodel::joiningPermille(t, 30000);
      CHECK(p >= last);
      last = p;
    }
  }

  // --- Every profile, both frame shapes -------------------------------------
  const char *previewDir = getenv("BOOT_SCREEN_PREVIEW_DIR");
  int bottomLayouts = 0, compactLayouts = 0;
  for (const auto &identity : board::GENERATED_BOARD_IDENTITIES) {
    const board::Config &cfg = board::configFor(identity.variant);
    if (!cfg.hasPanel()) continue;  // no screen, nothing to lay out
    const bool round = cfg.panel->roundDisplay;
    const bool square = cfg.panel->width == cfg.panel->height;
    for (int landscape = 0; landscape <= (square ? 0 : 1); ++landscape) {
      const int w = landscape ? cfg.panel->height : cfg.panel->width;
      const int h = landscape ? cfg.panel->width : cfg.panel->height;
      const Layout l = bootscreenmodel::layout(w, h, round);
      const int s = l.textScale;
      CHECK(l.width == w && l.height == h);
      CHECK(s >= 1 && s <= 4);
      CHECK(l.bar.x == (w - l.bar.w) / 2);
      CHECK(l.bar.w > 0 && l.bar.h >= 2);
      const bool micro = w <= 80 || h <= 48;
      if (micro) {
        ++compactLayouts;
        CHECK(l.compact);
        CHECK(l.image.x == 0 && l.image.y == 0);
        CHECK(l.image.w == 0 && l.image.h == 0);
        CHECK(l.textY == 1 && !l.textOverImage);
        CHECK(l.bar.y == h - 5 && l.bar.h == 4);
      } else {
        // The boot image is never scaled on a panel that can show it.
        CHECK(l.image.w == bootimage::WIDTH && l.image.h == bootimage::HEIGHT);
        // Centred across, every ordinary layout.
        CHECK(l.image.x == (w - bootimage::WIDTH) / 2);
        if (!l.compact) {
        ++bottomLayouts;
        // Yoda at the bottom centre; the bar at the screen's centre.
        CHECK(l.image.y + l.image.h == h);
        // Centred, or lifted just clear of the image where centred would touch
        // it (screens exactly twice its height).
        CHECK(l.bar.y + l.bar.h / 2 <= h / 2);
        CHECK(h / 2 - (l.bar.y + l.bar.h / 2) <= l.bar.h / 2 + 1);
        if (h >= 2 * bootimage::HEIGHT + l.bar.h) {
          CHECK(l.bar.y + l.bar.h / 2 == h / 2);
        }
        // The status line sits above the bar and clear of the image.
        CHECK(l.textY + 7 * s < l.bar.y);
        CHECK(l.textY + 7 * s <= l.image.y);
        // The bar never covers the image.
        CHECK(l.bar.y + l.bar.h <= l.image.y);
        CHECK(!l.textOverImage);
      } else {
        ++compactLayouts;
        CHECK(h < 2 * bootimage::HEIGHT);
        CHECK(l.image.y == (h - bootimage::HEIGHT) / 2);
        if (!l.textOverImage) CHECK(l.textY + 7 * s <= l.image.y);
        // The bar is in the bottom margin when there is one.
        if (h - (l.image.y + l.image.h) >= 4) {
          CHECK(l.bar.y >= l.image.y + l.image.h);
        }
        }
      }
      // Bar and the longest status line are on the glass.
      CHECK(onGlass(l, l.bar.x, l.bar.y, l.bar.x + l.bar.w, l.bar.y + l.bar.h));
      const int longest = bootscreenmodel::textWidth(
          bootscreenmodel::MAX_STATUS_CHARS, s);
      const int textX = (w - longest) / 2;
      // Only a frame narrower than the longest line at single size (the
      // 96x54 ST7735 on its side, 54 wide) clips it, as layout() documents.
      const bool clips = bootscreenmodel::textWidth(
                             bootscreenmodel::MAX_STATUS_CHARS, 1) > w;
      if (!clips && !onGlass(l, textX, l.textY, textX + longest, l.textY + 7 * s)) {
        printf("  %s %dx%d status line leaves the glass\n", identity.profile, w,
               h);
      }
      CHECK(clips ||
            onGlass(l, textX, l.textY, textX + longest, l.textY + 7 * s));
      CHECK(!clips || (s == 1 && l.textY >= 0 && l.textY + 7 <= h));

      // Pixels: background, the image unscaled where it is, bar fill.
      const bootscreenmodel::StageView join =
          bootscreenmodel::viewFor(Stage::JoiningWifi);
      const std::vector<uint8_t> screen =
          compose(l, join.text, 500, join.barColor);
      CHECK(pixelAt(screen, w, 0, 0) == bootscreenmodel::BACKGROUND ||
            l.textOverImage);
      if (!micro) {
        for (int iy = 0; iy < bootimage::HEIGHT; iy += 7) {
          for (int ix = 0; ix < bootimage::WIDTH; ix += 5) {
            const int x = l.image.x + ix, y = l.image.y + iy;
            // Glass smaller than the image (the 96x54 ST7735) shows its middle.
            if (x < 0 || y < 0 || x >= w || y >= h) continue;
            const bool underBar = y >= l.bar.y && y < l.bar.y + l.bar.h &&
                                  x >= l.bar.x && x < l.bar.x + l.bar.w;
            const bool underText =
                y >= l.textY - 1 && y <= l.textY + 7 * s + 1;
            if (underBar || underText) continue;
            CHECK(pixelAt(screen, w, x, y) == imagePixel(ix, iy));
          }
        }
      }
      const int midY = l.bar.y + l.bar.h / 2;
      const int inner0 = l.bar.h >= 4 ? l.bar.x + 1 : l.bar.x;
      CHECK(pixelAt(screen, w, inner0, midY) == join.barColor);
      CHECK(pixelAt(screen, w, l.bar.x + l.bar.w - 2, midY) ==
            bootscreenmodel::BAR_TRACK);
      const std::vector<uint8_t> full =
          compose(l, "ready", 1000, bootscreenmodel::BAR_READY);
      CHECK(pixelAt(full, w, l.bar.x + l.bar.w - 2, midY) ==
            bootscreenmodel::BAR_READY);
      // Some of the status text is drawn, in the text rows.
      int lit = 0;
      for (int y = l.textY; y < l.textY + 7 * s; ++y) {
        for (int x = 0; x < w; ++x) {
          lit += pixelAt(screen, w, x, y) == bootscreenmodel::TEXT_COLOR;
        }
      }
      CHECK(lit > 0);

      // Any run of rows composes exactly as the whole screen does, so a
      // partial repaint leaves no seam.
      for (int rows : {1, 7, 16}) {
        std::vector<uint8_t> strip((size_t)w * rows * 2);
        for (int y0 = 0; y0 < h; y0 += rows) {
          const int n = h - y0 < rows ? h - y0 : rows;
          bootscreenmodel::composeRows(strip.data(), l, join.text, 500,
                                       join.barColor, y0, n);
          CHECK(memcmp(strip.data(), screen.data() + (size_t)y0 * w * 2,
                       (size_t)n * w * 2) == 0);
        }
      }
      // The repaint regions cover what a text or a bar change touches.
      int t0, t1, b0, b1;
      bootscreenmodel::textRows(l, t0, t1);
      bootscreenmodel::barRows(l, b0, b1);
      const std::vector<uint8_t> other =
          compose(l, "preparing", 900, join.barColor);
      for (int y = 0; y < h; ++y) {
        const bool inRegion = (y >= t0 && y < t1) || (y >= b0 && y < b1);
        if (inRegion) continue;
        CHECK(memcmp(other.data() + (size_t)y * w * 2,
                     screen.data() + (size_t)y * w * 2, (size_t)w * 2) == 0);
      }

      if (previewDir != nullptr) {
        writePreview(previewDir,
                     std::string(identity.profile) + "-" + std::to_string(w) +
                         "x" + std::to_string(h),
                     l, screen);
      }
    }
  }
  // The two 128x128 panels (the 0.85 and the T-QT), the 172-high landscape
  // frames, both 96x54 frames, and both 72x40 OLED shapes are compact.
  CHECK(compactLayouts == 9);
  CHECK(bottomLayouts > 0);
  {
    const Layout small = bootscreenmodel::layout(128, 128, false);
    CHECK(small.compact);
    CHECK(small.image.x == 4 && small.image.y == 4);
    const Layout knob = bootscreenmodel::layout(240, 240, true);
    CHECK(!knob.compact);
    CHECK(knob.image.y == 120);
  }

  printf("boot screen: %d checks passed\n", checks);
  return 0;
}
