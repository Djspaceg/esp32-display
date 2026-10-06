#pragma once

typedef int gpio_num_t;
static constexpr gpio_num_t GPIO_NUM_NC = -1;
int gpio_get_level(gpio_num_t pin);
