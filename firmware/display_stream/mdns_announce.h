// The _espdisp._udp service and its TXT records (name, res, fw, proto, caps,
// chip, target), plus OTA's _arduino._tcp when OTA is active. Both the boot
// announce and every post-reconnect re-announce go through here.
#pragma once

void addMdnsService();
bool restartMdnsService();
