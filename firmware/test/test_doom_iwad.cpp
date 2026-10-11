// Host test for which game the Doom boot takes a WAD for (doom/src/
// d_iwad.c.inc D_FindIWAD, compiled unmodified by doom_iwad_unit.c).
//
// Rule: a WAD with a known IWAD name is that game (doom2.wad, freedoom2.wad
// are Doom II; doom1.wad is Doom); any other name is left unknown, so
// D_IdentifyVersion identifies it by its lumps (MAP01 or E1M1). A stored
// Doom II WAD taken for Doom would fail on its first E1M1 lookup.
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

extern "C" {
#include "d_iwad.h"
#include "d_mode.h"

char **myargv = nullptr;
int myargc = 0;

int M_CheckParmWithArgs(char *check, int num_args) {
  for (int i = 1; i + num_args < myargc; ++i) {
    if (strcmp(myargv[i], check) == 0) return i;
  }
  return 0;
}
boolean M_FileExists(char *) { return false; }
char *M_StringJoin(const char *, ...) { return nullptr; }
void I_Error(const char *error, ...) {
  va_list args;
  va_start(args, error);
  vfprintf(stderr, error, args);
  va_end(args);
  std::exit(3);
}
}

static int failures = 0;
#define CHECK(cond)                                                  \
  do {                                                               \
    if (!(cond)) {                                                   \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__,    \
                   __LINE__, #cond);                                 \
      ++failures;                                                    \
    }                                                                \
  } while (0)

static GameMission_t missionFor(const char *name) {
  static char arg0[] = "doom", flag[] = "-iwad";
  static char wad[32];
  std::snprintf(wad, sizeof(wad), "%s", name);
  static char *argv[] = {arg0, flag, wad, nullptr};
  myargv = argv;
  myargc = 3;
  GameMission_t mission = none;
  const char *found = D_FindIWAD(IWAD_MASK_DOOM, &mission);
  CHECK(found != nullptr && std::strcmp(found, name) == 0);
  return mission;
}

int main() {
  CHECK(missionFor("doom1.wad") == doom);
  CHECK(missionFor("doom2.wad") == doom2);
  CHECK(missionFor("freedoom2.wad") == doom2);
  CHECK(missionFor("freedoom1.wad") == doom);
  CHECK(missionFor("plutonia.wad") == pack_plut);
  CHECK(missionFor("doom18.wad") == none);
  CHECK(missionFor("miniwad.wad") == none);
  if (failures != 0) {
    std::fprintf(stderr, "test_doom_iwad: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("test_doom_iwad: ok\n");
  return 0;
}
