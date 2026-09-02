// The _espdisp._udp service and its TXT records (name, res, fw, proto, caps,
// chip, target), plus OTA's _arduino._tcp when OTA is active. Both the boot
// announce and the post-heal re-announce go through here.
#pragma once

void addMdnsService();
