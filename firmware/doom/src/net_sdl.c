// Network module stub for ESP32 (no multiplayer support)
// Replaces the SDL_net-based networking with no-ops.
#include "net_defs.h"
#include "doomtype.h"

static boolean NET_ESP32_InitClient(void) { return false; }
static boolean NET_ESP32_InitServer(void) { return false; }
static void NET_ESP32_SendPacket(net_addr_t *addr, net_packet_t *packet) {
    (void)addr; (void)packet;
}
static boolean NET_ESP32_RecvPacket(net_addr_t **addr, net_packet_t **packet) {
    (void)addr; (void)packet;
    return false;
}
static void NET_ESP32_AddrToString(net_addr_t *addr, char *buffer, int buffer_len) {
    (void)addr;
    if (buffer_len > 0) buffer[0] = '\0';
}
static void NET_ESP32_FreeAddress(net_addr_t *addr) { (void)addr; }
static net_addr_t* NET_ESP32_ResolveAddress(char *addr) { (void)addr; return NULL; }

net_module_t net_sdl_module = {
    NET_ESP32_InitClient,
    NET_ESP32_InitServer,
    NET_ESP32_SendPacket,
    NET_ESP32_RecvPacket,
    NET_ESP32_AddrToString,
    NET_ESP32_FreeAddress,
    NET_ESP32_ResolveAddress,
};
