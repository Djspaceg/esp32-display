// The _espdisp._udp service and its TXT records (name, res, fw, proto, caps,
// chip, target, ssid, ...), plus OTA's _arduino._tcp when OTA is active. Both the boot
// announce and every post-reconnect re-announce go through here.
#pragma once

void addMdnsService();
bool restartMdnsService();
// Whether the announced `ssid` record still names the network the WiFi
// worker last read. False when WiFi joined after the last announcement; true
// while the worker has no reading. Never issues a WiFi RPC once the worker runs.
bool mdnsSsidIsCurrent();
