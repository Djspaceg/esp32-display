// Lines typed on the serial port during a Doom boot, as Quake's go to its
// console: a few commands to save, load and check a game and to read or set
// a configuration variable without the touch screen. Part of the Doom unity
// build (after the engine, whose globals it reads); doom_mode.cpp feeds it
// whole lines from loopTask.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void doom_save_config(void) { M_SaveDefaults(); }

static void doom_serial_help(void) {
  doom_log("serial commands: where | map <episode> <map> | save <0-5> [name] |"
           " load <0-5> | get <variable> | set <variable> <value>");
}

void doom_serial_command(char* line) {
  // A command, a word, then the rest of the line (a save name or a value).
  char* argv[3] = {NULL, NULL, NULL};
  int argc = 0;
  argv[0] = strtok(line, " \t\r\n");
  if (argv[0] != NULL) argv[1] = strtok(NULL, " \t\r\n");
  if (argv[1] != NULL) argv[2] = strtok(NULL, "\r\n");
  while (argv[2] != NULL && (*argv[2] == ' ' || *argv[2] == '\t')) ++argv[2];
  if (argv[2] != NULL && *argv[2] == '\0') argv[2] = NULL;
  while (argc < 3 && argv[argc] != NULL) ++argc;
  if (argc == 0) return;
  const char* cmd = argv[0];
  if (strcmp(cmd, "where") == 0) {
    doom_log("where: gamestate %d, E%dM%d, leveltime %d, health %d, "
             "demo %d, menu %d",
             (int)gamestate, gameepisode, gamemap, leveltime,
             playeringame[consoleplayer] ? players[consoleplayer].health : 0,
             demoplayback ? 1 : 0, menuactive ? 1 : 0);
  } else if (strcmp(cmd, "map") == 0 && argc >= 3) {
    G_DeferedInitNew(sk_medium, atoi(argv[1]), atoi(argv[2]));
    doom_log("map: starting E%sM%s", argv[1], argv[2]);
  } else if (strcmp(cmd, "save") == 0 && argc >= 2) {
    const int slot = atoi(argv[1]);
    if (slot < 0 || slot > 5 || gamestate != GS_LEVEL || !usergame ||
        demoplayback) {
      doom_log("save: needs a slot 0-5 and a game in play");
      return;
    }
    G_SaveGame(slot, argc >= 3 ? argv[2] : (char*)"SERIAL");
  } else if (strcmp(cmd, "load") == 0 && argc >= 2) {
    const int slot = atoi(argv[1]);
    if (slot < 0 || slot > 5) {
      doom_log("load: needs a slot 0-5");
      return;
    }
    M_ClearMenus();
    G_LoadGame(P_SaveGameFile(slot));
  } else if (strcmp(cmd, "get") == 0 && argc >= 2) {
    const char* text = M_GetStrVariable(argv[1]);
    if (text != NULL) {
      doom_log("%s = \"%s\"", argv[1], text);
    } else {
      doom_log("%s = %d (%f)", argv[1], M_GetIntVariable(argv[1]),
               (double)M_GetFloatVariable(argv[1]));
    }
  } else if (strcmp(cmd, "set") == 0 && argc >= 3) {
    if (!M_SetVariable(argv[1], argv[2])) {
      doom_log("set: no variable %s", argv[1]);
      return;
    }
    doom_log("set %s %s", argv[1], argv[2]);
    M_SaveDefaults();
  } else {
    doom_serial_help();
  }
}
