// Inbound UDP transport (raw lwIP socket + dedicated receive task on the S3,
// AsyncUDP on the C6), the reply endpoint, and inbound dispatch. Frame
// packets are handed to frame_pipeline; control packets to control_apply.
#pragma once

#include <Arduino.h>

#include <stddef.h>
#include <stdint.h>

// Reply endpoint: source of the most recent packet from the Mac.
extern volatile uint32_t hbIp;
extern volatile uint16_t hbPort;

bool startInboundTransport();
void sendToSender(const uint8_t *data, size_t len);

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// CFGTUNE knobs (serial_config.cpp): the receive task's drain-yield bound and
// its handle for runtime priority experiments.
extern int tuneRxDrainYieldEvery;
extern TaskHandle_t rxTaskHandle;
#endif
