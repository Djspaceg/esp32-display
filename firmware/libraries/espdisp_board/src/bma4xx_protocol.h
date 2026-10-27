// Hardware-free BMA423/BMA456 accelerometer facts for host tests and
// board_motion.h: the LilyGO T-Watch-S3's IMU (BMA423, BMA456 on later
// batches; LilyGO probes both). Only the raw accelerometer is used, which
// needs no feature-engine configuration file.
//
// Register map and values from Bosch's BMA4 driver as SensorLib vendors it
// (the library LilyGO's T-Watch-S3 code runs):
// https://github.com/lewisxhe/SensorLib/blob/dff98e79753dedd7ba709d1e92d71b4353c55005/src/bosch/bma4xx/bma4_defs.h
// and its model IDs (BMA423 0x13, BMA456 0x16):
// https://github.com/lewisxhe/SensorLib/blob/dff98e79753dedd7ba709d1e92d71b4353c55005/src/sensor/accelerometer/bma/SensorBMA4XX.hpp#L196-L198
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace bma4xx {
/// SDO high: LilyGO's BMA4XX_I2C_ADDR_SDO_HIGH on this board.
static const uint8_t ADDRESS = 0x19;
static const uint8_t REG_CHIP_ID = 0x00;
static const uint8_t REG_DATA_X_LSB = 0x12;  // X, Y, Z, each LSB then MSB
static const uint8_t REG_ACC_CONF = 0x40;
static const uint8_t REG_ACC_RANGE = 0x41;
static const uint8_t REG_PWR_CONF = 0x7C;
static const uint8_t REG_PWR_CTRL = 0x7D;
static const uint8_t REG_CMD = 0x7E;
static const uint8_t CMD_SOFT_RESET = 0xB6;
static const uint8_t CHIP_BMA423 = 0x13;
static const uint8_t CHIP_BMA456 = 0x16;
/// PWR_CONF 0: advanced power save off, so registers can be written freely.
static const uint8_t PWR_CONF_ACTIVE = 0x00;
/// PWR_CTRL bit 2: accelerometer on.
static const uint8_t PWR_CTRL_ACC_EN = 0x04;
/// ACC_CONF: continuous (performance) mode, normal averaging, 100 Hz.
static const uint8_t ACC_CONF_100HZ = 0x80 | (2u << 4) | 0x08;
static const uint8_t ACC_RANGE_4G = 0x01;

inline bool isKnownChip(uint8_t id) {
  return id == CHIP_BMA423 || id == CHIP_BMA456;
}

/// Six data bytes to a sample. Each axis is 12 bits, left-aligned across its
/// LSB (bits 7:4) and MSB; read as one little-endian int16 with the empty low
/// nibble cleared it is 16 counts per bit, so at +/-4g 8192 counts per g,
/// the scale every motion consumer here assumes (the QMI8658's at +/-4g).
inline void decode(const uint8_t data[6], int16_t &x, int16_t &y,
                   int16_t &z) {
  x = (int16_t)(((uint16_t)data[1] << 8 | data[0]) & 0xFFF0);
  y = (int16_t)(((uint16_t)data[3] << 8 | data[2]) & 0xFFF0);
  z = (int16_t)(((uint16_t)data[5] << 8 | data[4]) & 0xFFF0);
}
}  // namespace bma4xx
