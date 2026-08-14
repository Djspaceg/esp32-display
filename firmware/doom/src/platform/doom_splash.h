// Doom Easter Egg splash screen
//
// Shown on the AMOLED while the WAD is being memory-mapped and the engine
// initializes (~200ms). A simple "DOOM" text rendered large in the classic
// red-on-black style, plus a "Loading..." indicator.
//
// This is procedurally drawn (no bitmap asset) to keep the binary small.
// MIT licensed (not part of the GPL engine).
#pragma once

#include <stdint.h>
#include <string.h>

namespace doom_splash {

// Classic Doom red: RGB565 big-endian
static const uint16_t DOOM_RED = __builtin_bswap16(0xC800);     // dark red
static const uint16_t DOOM_ORANGE = __builtin_bswap16(0xFB20);  // fire orange
static const uint16_t DOOM_YELLOW = __builtin_bswap16(0xFFE0);  // highlight
static const uint16_t BLACK = 0x0000;
static const uint16_t DIM_RED = __builtin_bswap16(0x6000);      // very dark red

// Simple 5x7 pixel font for "DOOM" and "Loading..."
// Each letter is a 5-wide column-encoded bitmap (LSB = top row)
static const uint8_t FONT_D[] = {0x7F, 0x41, 0x41, 0x22, 0x1C};
static const uint8_t FONT_O[] = {0x3E, 0x41, 0x41, 0x41, 0x3E};
static const uint8_t FONT_M[] = {0x7F, 0x02, 0x04, 0x02, 0x7F};
static const uint8_t FONT_L[] = {0x7F, 0x40, 0x40, 0x40, 0x40};
static const uint8_t FONT_a[] = {0x20, 0x54, 0x54, 0x54, 0x78};
static const uint8_t FONT_d[] = {0x38, 0x44, 0x44, 0x44, 0x7F};
static const uint8_t FONT_i[] = {0x00, 0x44, 0x7D, 0x40, 0x00};
static const uint8_t FONT_n[] = {0x7C, 0x08, 0x04, 0x04, 0x78};
static const uint8_t FONT_g[] = {0x08, 0x54, 0x54, 0x54, 0x3C};
static const uint8_t FONT_dot[] = {0x00, 0x60, 0x60, 0x00, 0x00};

// Draw a single character at scale factor into an RGB565 buffer
static void draw_char(uint16_t* buf, int buf_w, int x, int y,
                      const uint8_t* glyph, int scale, uint16_t color) {
    for (int col = 0; col < 5; col++) {
        uint8_t bits = glyph[col];
        for (int row = 0; row < 7; row++) {
            if (bits & (1 << row)) {
                // Fill a scale x scale block
                for (int sy = 0; sy < scale; sy++) {
                    for (int sx = 0; sx < scale; sx++) {
                        int px = x + col * scale + sx;
                        int py = y + row * scale + sy;
                        if (px >= 0 && px < buf_w && py >= 0 && py < buf_w) {
                            buf[py * buf_w + px] = color;
                        }
                    }
                }
            }
        }
    }
}

/// Render the Doom splash screen into a 466x466 RGB565 buffer.
/// Call once, then blit to the display.
static void render(uint16_t* buf) {
    const int W = 466;

    // Black background
    memset(buf, 0, W * W * sizeof(uint16_t));

    // "DOOM" in large letters (scale 12 = ~60px per letter, ~280px total)
    const int scale = 12;
    const int char_w = 5 * scale + scale;  // 5 cols + 1 col spacing
    const int total_w = 4 * char_w - scale;  // 4 letters, no trailing space
    const int x_start = (W - total_w) / 2;
    const int y_doom = (W / 2) - (7 * scale) - 20;  // slightly above center

    // Draw with gradient: top = yellow, middle = orange, bottom = red
    // We'll draw three passes with clipping to simulate a vertical gradient
    const uint8_t* letters[] = {FONT_D, FONT_O, FONT_O, FONT_M};

    for (int li = 0; li < 4; li++) {
        int lx = x_start + li * char_w;

        // Bottom third: dark red
        draw_char(buf, W, lx, y_doom, letters[li], scale, DOOM_RED);

        // Middle third: overwrite top 2/3 with orange
        for (int col = 0; col < 5; col++) {
            uint8_t bits = letters[li][col];
            for (int row = 0; row < 5; row++) {  // top 5 of 7 rows
                if (bits & (1 << row)) {
                    for (int sy = 0; sy < scale; sy++) {
                        for (int sx = 0; sx < scale; sx++) {
                            int px = lx + col * scale + sx;
                            int py = y_doom + row * scale + sy;
                            if (px >= 0 && px < W && py >= 0 && py < W) {
                                buf[py * W + px] = DOOM_ORANGE;
                            }
                        }
                    }
                }
            }
        }

        // Top third: overwrite top 2 rows with yellow
        for (int col = 0; col < 5; col++) {
            uint8_t bits = letters[li][col];
            for (int row = 0; row < 2; row++) {
                if (bits & (1 << row)) {
                    for (int sy = 0; sy < scale; sy++) {
                        for (int sx = 0; sx < scale; sx++) {
                            int px = lx + col * scale + sx;
                            int py = y_doom + row * scale + sy;
                            if (px >= 0 && px < W && py >= 0 && py < W) {
                                buf[py * W + px] = DOOM_YELLOW;
                            }
                        }
                    }
                }
            }
        }
    }

    // "Loading..." in smaller text below (scale 3)
    const int sm_scale = 3;
    const int sm_char_w = 5 * sm_scale + sm_scale;
    const uint8_t* loading[] = {FONT_L, FONT_a, FONT_d, FONT_i, FONT_n, FONT_g,
                                 FONT_dot, FONT_dot, FONT_dot};
    const int load_len = 9;
    const int load_total_w = load_len * sm_char_w - sm_scale;
    const int load_x = (W - load_total_w) / 2;
    const int load_y = y_doom + 7 * scale + 40;

    for (int i = 0; i < load_len; i++) {
        draw_char(buf, W, load_x + i * sm_char_w, load_y,
                  loading[i], sm_scale, DIM_RED);
    }
}

}  // namespace doom_splash
