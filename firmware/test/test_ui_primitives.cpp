#include <cstdio>
#include <cstring>
#include <vector>

#include "../display_stream/ui_icons.h"

static int checks = 0;
#define CHECK(condition)                                                        \
  do {                                                                          \
    ++checks;                                                                   \
    if (!(condition)) {                                                        \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);             \
      return 1;                                                                 \
    }                                                                           \
  } while (0)

static uint16_t pixel(const std::vector<uint8_t> &buf, int width, int x, int y) {
  const size_t at = ((size_t)y * width + x) * 2;
  return (uint16_t)((buf[at] << 8) | buf[at + 1]);
}

int main() {
  constexpr int width = 48, height = 48;
  std::vector<uint8_t> pixels((size_t)width * height * 2);

  uiprim::fillRoundedRect(pixels.data(), width, height, {4, 4, 24, 16}, 6,
                          0xFFFF);
  CHECK(pixel(pixels, width, 4, 4) == 0);
  CHECK(pixel(pixels, width, 16, 12) == 0xFFFF);
  CHECK(pixel(pixels, width, 5, 5) != 0);
  uiprim::strokeRoundedRect(pixels.data(), width, height, {30, 4, 14, 14}, 5,
                            2, 0x0C3F);
  CHECK(pixel(pixels, width, 37, 4) == 0x0C3F);
  CHECK(pixel(pixels, width, 37, 11) == 0);

  uiprim::fillVerticalGradient(pixels.data(), width, height, {0, 24, 16, 20},
                               0x0000, 0xFFFF);
  CHECK(pixel(pixels, width, 2, 24) != pixel(pixels, width, 2, 43));
  CHECK(pixel(pixels, width, 2, 32) != pixel(pixels, width, 3, 32));
  uiprim::fillRadialGradient(pixels.data(), width, height, {16, 24, 32, 24},
                             32, 36, 12, 0xFFFF, 0x0000);
  CHECK(pixel(pixels, width, 32, 36) > pixel(pixels, width, 16, 24));

  std::memset(pixels.data(), 0, pixels.size());
  uiicons::wifi(pixels.data(), width, height, 12, 18, 10, 0xFFFF, 3);
  uiicons::battery(pixels.data(), width, height, 23, 12, 16, 8, 0xFFFF, 75);
  uiicons::check(pixels.data(), width, height, 5, 30, 10, 0xFFFF);
  uiicons::chevron(pixels.data(), width, height, 26, 29, 10, 0xFFFF);
  uiicons::pressHint(pixels.data(), width, height, 36, 30, 0xFFFF);
  int lit = 0;
  for (uint8_t value : pixels) lit += value != 0;
  CHECK(lit > 100);

  printf("ui primitives: %d checks passed\n", checks);
  return 0;
}
