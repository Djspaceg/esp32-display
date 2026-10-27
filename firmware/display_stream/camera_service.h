#pragma once

#include <stddef.h>
#include <stdint.h>

bool startCameraService();
bool cameraAvailable();
bool handleCameraCommand(const uint8_t *data, size_t len);
void serviceCamera();
