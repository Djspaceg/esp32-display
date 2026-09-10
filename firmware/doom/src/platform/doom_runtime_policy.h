// Hardware-free Doom display and touch policy.
//
// Kept C-compatible because the renderer is compiled inside the C unity build,
// while the host test suite includes the same policy from C++.
#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int panel_width;
    int panel_height;
    int scaled_width;
    int scaled_height;
    int x_offset;
    int y_offset;
    bool round_mask;
} doom_frame_layout_t;

typedef enum {
    DOOM_CONTROLS_IMU_TOUCH,
    DOOM_CONTROLS_TOUCH_ONLY,
} doom_control_scheme_t;

typedef enum {
    DOOM_TOUCH_ZONE_AIM,
    DOOM_TOUCH_ZONE_MOVE,
} doom_touch_zone_t;

static inline doom_frame_layout_t doom_frame_layout_for_panel(
    int panel_width, int panel_height, bool round_mask) {
    doom_frame_layout_t layout = {
        panel_width, panel_height, 0, 0, 0, 0, round_mask,
    };
    if (panel_width <= 0 || panel_height <= 0) return layout;

    layout.scaled_width = panel_width;
    layout.scaled_height = (panel_width * 200) / 320;
    if (layout.scaled_height > panel_height) {
        layout.scaled_height = panel_height;
        layout.scaled_width = (panel_height * 320) / 200;
    }
    layout.x_offset = (panel_width - layout.scaled_width) / 2;
    layout.y_offset = (panel_height - layout.scaled_height) / 2;
    return layout;
}

static inline doom_touch_zone_t doom_touch_zone_for_press(
    doom_control_scheme_t scheme, int panel_width, int start_x) {
    if (scheme == DOOM_CONTROLS_TOUCH_ONLY &&
        panel_width > 0 && start_x < panel_width / 2) {
        return DOOM_TOUCH_ZONE_MOVE;
    }
    return DOOM_TOUCH_ZONE_AIM;
}

static inline int doom_touch_axis_delta(
    int current, int origin, int deadzone, int max_magnitude) {
    const int displacement = current - origin;
    const int absolute = displacement < 0 ? -displacement : displacement;
    if (absolute <= deadzone) return 0;
    int magnitude = absolute - deadzone;
    if (magnitude > max_magnitude) magnitude = max_magnitude;
    return displacement < 0 ? -magnitude : magnitude;
}
