// CD Audio stubs for ESP32 (no CD-ROM hardware)
// Original file required SDL2. All functions are no-ops.
#include "doomtype.h"

int I_CDMusInit(void) { return 0; }
int I_CDMusPlay(int track) { (void)track; return 0; }
int I_CDMusStop(void) { return 0; }
int I_CDMusResume(void) { return 0; }
int I_CDMusSetVolume(int volume) { (void)volume; return 0; }
int I_CDMusFirstTrack(void) { return 0; }
int I_CDMusLastTrack(void) { return 0; }
int I_CDMusTrackLength(int track) { (void)track; return 0; }
