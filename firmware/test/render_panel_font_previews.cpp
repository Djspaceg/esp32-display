// Host-only contact sheets for the firmware's static panel renderers. This
// file selects sample state and arranges their output; it owns no UI pixels.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../display_stream/boot_screen_model.h"
#include "../display_stream/static_ui_renderer.h"

static void writePpm(const std::string &path, const std::vector<uint8_t> &pixels,
                     int width, int height) {
  FILE *file = fopen(path.c_str(), "wb");
  if (file == nullptr) {
    perror(path.c_str());
    exit(1);
  }
  fprintf(file, "P6\n%d %d\n255\n", width, height);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const size_t at = ((size_t)y * width + x) * 2;
      const uint16_t color = (uint16_t)((pixels[at] << 8) | pixels[at + 1]);
      fputc(((color >> 11) & 0x1F) * 255 / 31, file);
      fputc(((color >> 5) & 0x3F) * 255 / 63, file);
      fputc((color & 0x1F) * 255 / 31, file);
    }
  }
  fclose(file);
}

static void drawBoot(std::vector<uint8_t> &pixels, int width, int height,
                     bool round, uint16_t diagonalTenthsMm) {
  const bootscreenmodel::Layout layout =
      bootscreenmodel::layout(width, height, round, diagonalTenthsMm);
  const bootscreenmodel::StageView view =
      bootscreenmodel::viewFor(bootscreenmodel::Stage::JoiningWifi);
  bootscreenmodel::composeRows(pixels.data(), layout, view.text, 550,
                               view.barColor, 0, height);
  staticui::maskOutsideRoundPanel(
      {pixels.data(), width, height, round, diagonalTenthsMm});
}

static void drawSurvey(std::vector<uint8_t> &pixels, int width, int height,
                       bool round, uint16_t diagonalTenthsMm) {
  staticui::drawSurvey(
      {pixels.data(), width, height, round, diagonalTenthsMm}, "studio-wifi",
      -64, "Good", "192.168.1.42", "2.1.0", "Battery 82% charging", "close",
      true);
}

static void drawPresets(std::vector<uint8_t> &pixels, int width, int height,
                        bool round, uint16_t diagonalTenthsMm) {
  const char *labels[] = {"studio-wifi", "backup-link"};
  const uint8_t slots[] = {1, 2};
  staticui::drawSelector(
      {pixels.data(), width, height, round, diagonalTenthsMm}, "WiFi presets",
      labels, slots, 2, 0, 0, true);
}

static void drawIdle(std::vector<uint8_t> &pixels, int width, int height,
                     bool round, uint16_t diagonalTenthsMm) {
  const char *lines[] = {"ESPDisplay", "192.168.1.42", "WiFi -64 dBm"};
  staticui::drawIdle({pixels.data(), width, height, round, diagonalTenthsMm},
                     lines, 3);
}

static void drawStatus(std::vector<uint8_t> &pixels, int width, int height,
                       bool round, uint16_t diagonalTenthsMm) {
  staticui::Panel panel = {pixels.data(), width, height, round,
                            diagonalTenthsMm};
  uitheme::background(panel.pixels, panel.width, panel.height);
  const int margin = wifiselector::safeMargin(width, height, round);
  const int pillHeight = wifiselector::controlHeight(height) + 10;
  staticui::drawStatusPill(
      panel, {(int16_t)margin, (int16_t)((height - pillHeight) / 2),
              (int16_t)(width - 2 * margin), (int16_t)pillHeight},
      "Streaming", "Battery 82%");
  staticui::maskOutsideRoundPanel(panel);
}

static void drawModeMenu(std::vector<uint8_t> &pixels, int width, int height,
                         bool round, uint16_t diagonalTenthsMm) {
  const char *labels[] = {"Streaming", "Doom"};
  staticui::drawSelector(
      {pixels.data(), width, height, round, diagonalTenthsMm}, "Choose a mode",
      labels, nullptr, 2, 0, -1, false, true);
}

typedef void (*Screen)(std::vector<uint8_t> &, int, int, bool, uint16_t);

static void preview(const char *directory, const char *name, int width,
                    int height, bool round, uint16_t diagonalTenthsMm) {
  const Screen screens[] = {drawBoot, drawSurvey, drawPresets,
                            drawIdle, drawStatus, drawModeMenu};
  const int gutter = width <= 128 ? 2 : 0;
  const int sheetWidth = width * 3 + gutter * 2;
  const int sheetHeight = height * 2 + gutter;
  std::vector<uint8_t> sheet((size_t)sheetWidth * sheetHeight * 2);
  for (int tile = 0; tile < 6; ++tile) {
    std::vector<uint8_t> panel((size_t)width * height * 2);
    screens[tile](panel, width, height, round, diagonalTenthsMm);
    const int xOffset = tile % 3 * (width + gutter);
    const int yOffset = tile / 3 * (height + gutter);
    for (int y = 0; y < height; ++y) {
      memcpy(sheet.data() + ((size_t)(yOffset + y) * sheetWidth + xOffset) * 2,
             panel.data() + (size_t)y * width * 2, (size_t)width * 2);
    }
  }
  writePpm(std::string(directory) + "/" + name + ".ppm", sheet, sheetWidth,
           sheetHeight);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s OUTPUT_DIRECTORY\n", argv[0]);
    return 2;
  }
  preview(argv[1], "amoled-175-round", 466, 466, true, 445);
  preview(argv[1], "lcd-185-round", 360, 360, true, 470);
  preview(argv[1], "lcd-154-square", 240, 240, false, 391);
  preview(argv[1], "lcd-085-small", 128, 128, false, 216);
  preview(argv[1], "tqt-128", 128, 128, false, 216);
  preview(argv[1], "xiao-042-color", 96, 54, false, 107);
  preview(argv[1], "xiaoml-oled-72x40", 72, 40, false, 107);
  preview(argv[1], "p4-720", 720, 720, true, 1016);
  return 0;
}
