// The only task that talks to the WiFi driver after setup(). On the P4 family
// WiFi lives on a C6 co-processor behind ESP-Hosted, so reading RSSI or asking
// for a reconnect is an RPC that blocks its caller for up to 5 s
// (DEFAULT_RPC_RSP_TIMEOUT) whenever the C6 is not answering. loop() feeds a
// 10 s task watchdog once per pass, so two such waits in one pass rebooted the
// board. The loop now reads a cached RSSI and SSID and posts reconnects here;
// this task is on no watchdog and may wait as long as the RPC takes.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace wifiworker {

// How often the worker samples RSSI while associated, and how old a sample may
// be before rssi() reports it unknown.
constexpr uint32_t RSSI_POLL_MS = 500;  // the survey meter redraws at 2 Hz
constexpr uint32_t RSSI_STALE_MS = 10000;
// Associated, yet no RSSI answer for this long: the co-processor has stopped
// answering. The watchdog reboot used to recover that by accident (a host
// boot resets the C6); now the WiFi supervisor treats it as an unresponsive
// radio and takes its one restart.
constexpr uint32_t COPROCESSOR_SILENT_MS = 30000;
// The worker reads the joined network's SSID once per association and after
// each reconnect or reassociate it runs, right after an RSSI answer (so a
// silent C6 is not asked). A read that fails is retried this much later.
constexpr uint32_t SSID_POLL_MS = 5000;

bool start();

// Last RSSI sample in dBm, or 0 (what WiFi.RSSI() returns on failure) when
// there is none from the last RSSI_STALE_MS. Never blocks.
int rssi();

// Copies the SSID of the network joined (read by the worker on this
// association) into out, NUL-terminated, and returns true; returns false with
// out empty when the worker has not read one yet or the link is down. If the
// worker never started, reads WiFi.SSID() on the caller instead, as the
// requests below do. Never blocks otherwise.
bool ssid(char *out, size_t len);

// True while associated with no RSSI answer for COPROCESSOR_SILENT_MS.
bool coprocessorSilent();

// WiFi.reconnect(), run on the worker. The command's result arrives later
// through takeReconnectResult(). If the worker never started, both requests
// run on the caller, as they did before the worker existed.
void requestReconnect();
// WiFi.disconnect() then WiFi.reconnect(), run on the worker (link heal).
void requestReassociate();
// True once per finished requestReconnect(), with whether the driver accepted
// the command.
bool takeReconnectResult(bool &accepted);

// One pass of the worker: run a pending request, then sample RSSI if due and
// read the SSID if one is owed.
// The task calls it in a loop; host tests call it directly.
void serviceOnce(uint32_t waitMs);

}  // namespace wifiworker
