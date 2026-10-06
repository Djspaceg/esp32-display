// Host test for the card a Doom boot that cannot start shows before it
// restarts (display_stream/doom_failure_screen.h): on every Doom panel the
// text stays on the glass, round corners included, and a long reason wraps
// rather than running off the edge.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "../display_stream/doom_failure_screen.h"

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      return 1;                                              \
    }                                                        \
  } while (0)

struct Panel {
  int width;
  int height;
  bool round;
};

// Every panel a Doom-capable profile carries (generated_board_configs.h).
static const Panel DOOM_PANELS[] = {
    {128, 128, false}, {170, 320, false}, {172, 320, false},
    {240, 240, false}, {240, 240, true},  {360, 360, true},
    {466, 466, true},  {720, 720, false}, {720, 720, true},
    {800, 800, true},
};

static const char *LONG_REASON =
    "I_Error: W_GetNumForName: STBAR not found while loading the status bar "
    "graphics for episode one of the shareware release";

static int wrapsAndMarksTruncation() {
  char lines[doomfail::MAX_REASON_LINES][doomfail::LINE_CAP];
  CHECK(doomfail::wrapText("touch unavailable", 20, lines, 4) == 1);
  CHECK(strcmp(lines[0], "touch unavailable") == 0);

  CHECK(doomfail::wrapText("Doom WAD is missing or invalid", 12, lines, 4) == 3);
  CHECK(strcmp(lines[0], "Doom WAD is") == 0);
  CHECK(strcmp(lines[1], "missing or") == 0);
  CHECK(strcmp(lines[2], "invalid") == 0);

  // An unbroken word longer than a line is split, not dropped.
  CHECK(doomfail::wrapText("ABCDEFGHIJKLMNOP", 10, lines, 4) == 2);
  CHECK(strcmp(lines[0], "ABCDEFGHIJ") == 0);
  CHECK(strcmp(lines[1], "KLMNOP") == 0);

  // A reason cut at the line limit says so.
  const int n = doomfail::wrapText(LONG_REASON, 20, lines, 4);
  CHECK(n == 4);
  CHECK(strlen(lines[3]) <= 20);
  CHECK(strcmp(lines[3] + strlen(lines[3]) - 3, "...") == 0);
  for (int i = 0; i < n; i++) CHECK(strlen(lines[i]) <= 20);
  return 0;
}

static bool isBackground(const std::vector<uint8_t> &buf, size_t pixel) {
  return buf[pixel * 2] == (doomfail::BACKGROUND >> 8) &&
         buf[pixel * 2 + 1] == (doomfail::BACKGROUND & 0xFF);
}

static int textStaysOnTheGlass(const Panel &panel, const char *reason) {
  std::vector<uint8_t> buf((size_t)panel.width * panel.height * 2, 0);
  doomfail::compose(buf.data(), panel.width, panel.height, panel.round, reason);
  const int margin =
      doomfail::textMargin(panel.width, panel.height, panel.round);
  const float cx = panel.width / 2.0f, cy = panel.height / 2.0f;
  const float radius = (panel.width < panel.height ? panel.width : panel.height) / 2.0f;
  int drawn = 0;
  int outsideBox = 0;
  int outsideGlass = 0;
  for (int y = 0; y < panel.height; y++) {
    for (int x = 0; x < panel.width; x++) {
      if (isBackground(buf, (size_t)y * panel.width + x)) continue;
      drawn++;
      // The outline reaches one pixel past the glyph box.
      if (x < margin - 1 || x >= panel.width - margin + 1 ||
          y < margin - 1 || y >= panel.height - margin + 1) {
        outsideBox++;
      }
      const float dx = x + 0.5f - cx, dy = y + 0.5f - cy;
      if (panel.round && std::sqrt(dx * dx + dy * dy) > radius) outsideGlass++;
    }
  }
  CHECK(drawn > 0);
  CHECK(outsideBox == 0);
  CHECK(outsideGlass == 0);
  return 0;
}

int main() {
  if (wrapsAndMarksTruncation() != 0) return 1;
  for (const Panel &panel : DOOM_PANELS) {
    if (textStaysOnTheGlass(panel, "Doom WAD unusable: doom_wad is past the 16 MiB flash map") != 0 ||
        textStaysOnTheGlass(panel, LONG_REASON) != 0 ||
        textStaysOnTheGlass(panel, "") != 0) {
      printf("  on a %dx%d%s panel\n", panel.width, panel.height,
             panel.round ? " round" : "");
      return 1;
    }
  }
  printf("test_doom_failure_screen: %d checks passed\n", checks);
  return 0;
}
