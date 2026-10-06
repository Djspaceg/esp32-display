// The shipping P4 image is built with CONFIG_LOG_MAXIMUM_LEVEL=1, which
// removes Arduino C++ ESP_LOGx lines and leaves C ones at the mercy of the log
// level. This fake removes them all, so a test only sees what reaches Serial.
#pragma once

#define ESP_LOGE(tag, ...) ((void)(tag))
#define ESP_LOGW(tag, ...) ((void)(tag))
#define ESP_LOGI(tag, ...) ((void)(tag))
