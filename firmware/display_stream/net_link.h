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

// CFGTUNE knobs (serial_config.cpp): meaningful only when the selected
// PlatformConfig uses the raw lwIP receive task.
extern int tuneRxDrainYieldEvery;
extern TaskHandle_t rxTaskHandle;

#if defined(ESPDISP_HOST_AUDIO_TEST)
void hostHandleInbound(const uint8_t *data, size_t len, uint32_t remoteIp,
                       uint16_t remotePort);
#endif
