// Host-only typography previews for the panel UI. Produces one PPM contact
// sheet per requested panel size; tools can convert the files to PNG without
// introducing an image dependency.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../display_stream/boot_screen_model.h"
#include "../display_stream/glyph_draw.h"

static void put(std::vector<uint8_t> &pixels, int width, int x, int y,
                uint16_t color) {
  const size_t at = ((size_t)y * width + x) * 2;
  pixels[at] = (uint8_t)(color >> 8);
  pixels[at + 1] = (uint8_t)color;
}

static void fill(std::vector<uint8_t> &pixels, int width, int x0, int y0,
                 int x1, int y1, uint16_t color) {
  for (int y = y0; y < y1; ++y) {
    for (int x = x0; x < x1; ++x) put(pixels, width, x, y, color);
  }
}

static void text(std::vector<uint8_t> &pixels, int width, int height, int x,
                 int y, const char *value, TextStyle style, uint16_t color,
                 bool outline = false) {
  if (outline) {
    for (int dy = -1; dy <= 1; ++dy) {
      for (int dx = -1; dx <= 1; ++dx) {
        if (dx || dy) drawText(pixels.data(), width, height, x + dx, y + dy,
                               value, 0x0000, style);
      }
    }
  }
  drawText(pixels.data(), width, height, x, y, value, color, style);
}

static void centered(std::vector<uint8_t> &pixels, int width, int height,
                     int y, const char *value, TextStyle style,
                     uint16_t color, bool outline = false) {
  text(pixels, width, height, (width - textWidth(value, style)) / 2, y, value,
       style, color, outline);
}

static void maskRound(std::vector<uint8_t> &pixels, int width, int height) {
  const int side = width < height ? width : height;
  const long radius2 = (long)side * side;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const long dx = 2L * x + 1 - width;
      const long dy = 2L * y + 1 - height;
      if (dx * dx + dy * dy > radius2) put(pixels, width, x, y, 0);
    }
  }
}

static void boot(std::vector<uint8_t> &pixels, int width, int height,
                 bool round) {
  const bootscreenmodel::Layout layout =
      bootscreenmodel::layout(width, height, round);
  bootscreenmodel::composeRows(pixels.data(), layout, "joining WiFi", 560,
                               bootscreenmodel::BAR_PROGRESS, 0, height);
}

static void survey(std::vector<uint8_t> &pixels, int width, int height) {
  fill(pixels, width, 0, 0, width, height, 0);
  const TextStyle small = smallTextStyle(width, height);
  const TextStyle mono = monoTextStyle(width, height);
  centered(pixels, width, height, height / 12, "studio-wifi", small, 0xFFFF);
  centered(pixels, width, height, height / 4, "-64", mono, 0x07E0);
  centered(pixels, width, height, height / 4 + textLineHeight(mono), "dBm, good",
           small, 0x07E0);
  centered(pixels, width, height, height * 5 / 8, "IP 192.168.1.42", small,
           0xFFFF);
  centered(pixels, width, height, height * 5 / 8 + textLineHeight(small),
           "ESPDisplay", small, 0xFFFF);
  fill(pixels, width, 4, height - textLineHeight(small) - 5, width - 4,
       height - 4, 0x03EF);
  centered(pixels, width, height, height - textLineHeight(small) - 4,
           "WIFI PRESETS", small, 0xFFFF);
}

static void picker(std::vector<uint8_t> &pixels, int width, int height) {
  fill(pixels, width, 0, 0, width, height, 0x0006);
  const TextStyle small = smallTextStyle(width, height);
  const TextStyle large = largeTextStyle(width, height);
  centered(pixels, width, height, 4, "WIFI PRESETS", large, 0xFFFF);
  const int rowH = textLineHeight(small) + 8;
  const int start = height / 3;
  for (int row = 0; row < 2; ++row) {
    const int y = start + row * rowH;
    fill(pixels, width, 5, y, width - 5, y + rowH - 2,
         row == 0 ? 0x03EF : 0x1082);
    text(pixels, width, height, 8, y + 3,
         row == 0 ? "*1 studio-wifi" : " 2 backup-link", small, 0xFFFF);
  }
  fill(pixels, width, 5, height - rowH - 4, width - 5, height - 4, 0x03EF);
  centered(pixels, width, height, height - rowH - 1, "CONNECT", small, 0xFFFF);
}

static void idle(std::vector<uint8_t> &pixels, int width, int height) {
  for (int y = 0; y < height; ++y) {
    const uint16_t blue = (uint16_t)(0x0004 + (y * 3 / (height ? height : 1)));
    fill(pixels, width, 0, y, width, y + 1, blue);
  }
  const TextStyle small = smallTextStyle(width, height);
  const int lineH = textLineHeight(small);
  const int y = height / 3;
  centered(pixels, width, height, y, "ESPDisplay", small, 0xFFFF, true);
  centered(pixels, width, height, y + lineH, "192.168.1.42", small, 0xFFFF, true);
  centered(pixels, width, height, y + 2 * lineH, "wifi -64 dBm", small, 0xFFFF,
           true);
}

static void info(std::vector<uint8_t> &pixels, int width, int height) {
  fill(pixels, width, 0, 0, width, height, 0x2128);
  const TextStyle small = smallTextStyle(width, height);
  fill(pixels, width, 0, 0, width, textLineHeight(small) + 3, 0x0000);
  centered(pixels, width, height, 1, "Battery 82% charging", small, 0xFFFF, true);
  const TextStyle large = largeTextStyle(width, height);
  centered(pixels, width, height, height / 2 - textHeight(large) / 2,
           "STREAMING", large, 0x07E0);
}

static void menu(std::vector<uint8_t> &pixels, int width, int height) {
  fill(pixels, width, 0, 0, width, height, 0x0006);
  const TextStyle large = largeTextStyle(width, height);
  const TextStyle small = smallTextStyle(width, height);
  centered(pixels, width, height, 4, "CHOOSE A MODE", large, 0xFFFF);
  const int rowH = textLineHeight(large) + 8;
  const int first = height / 3;
  fill(pixels, width, 5, first, width - 5, first + rowH, 0x03EF);
  centered(pixels, width, height, first + 3, "STREAMING", large, 0xFFFF);
  centered(pixels, width, height, first + rowH + 5, "DOOM", large, 0xFFFF);
  centered(pixels, width, height, height - textLineHeight(small) - 3,
           "BOOT: NEXT  HOLD: START", small, 0x8410);
}

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
      const uint16_t c = (uint16_t)((pixels[at] << 8) | pixels[at + 1]);
      fputc(((c >> 11) & 0x1F) * 255 / 31, file);
      fputc(((c >> 5) & 0x3F) * 255 / 63, file);
      fputc((c & 0x1F) * 255 / 31, file);
    }
  }
  fclose(file);
}

static void preview(const char *directory, const char *name, int width,
                    int height, bool round) {
  typedef void (*Screen)(std::vector<uint8_t> &, int, int);
  const Screen screens[] = {survey, picker, idle, info, menu};
  const int sheetW = width * 3;
  const int sheetH = height * 2;
  std::vector<uint8_t> sheet((size_t)sheetW * sheetH * 2);
  for (int tile = 0; tile < 6; ++tile) {
    std::vector<uint8_t> panel((size_t)width * height * 2);
    if (tile == 0) {
      boot(panel, width, height, round);
    } else {
      screens[tile - 1](panel, width, height);
    }
    if (round) maskRound(panel, width, height);
    const int ox = tile % 3 * width;
    const int oy = tile / 3 * height;
    for (int y = 0; y < height; ++y) {
      memcpy(sheet.data() + ((size_t)(oy + y) * sheetW + ox) * 2,
             panel.data() + (size_t)y * width * 2, (size_t)width * 2);
    }
  }
  writePpm(std::string(directory) + "/" + name + ".ppm", sheet, sheetW, sheetH);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s OUTPUT_DIRECTORY\n", argv[0]);
    return 2;
  }
  preview(argv[1], "amoled-175-round", 466, 466, true);
  preview(argv[1], "lcd-185-round", 360, 360, true);
  preview(argv[1], "lcd-154-square", 240, 240, false);
  preview(argv[1], "lcd-085-small", 128, 128, false);
  preview(argv[1], "tqt-128", 128, 128, false);
  preview(argv[1], "xiaoml-oled-72x40", 72, 40, false);
  preview(argv[1], "p4-720", 720, 720, true);
  return 0;
}
