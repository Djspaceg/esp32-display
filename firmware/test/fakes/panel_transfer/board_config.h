#pragma once

namespace board {
struct Config {
  bool i2c = false;

  bool isI2c() const { return i2c; }
};
}
