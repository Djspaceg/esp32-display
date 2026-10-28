#!/bin/zsh
# Change this one team ID after the paid Apple Developer team becomes active.
ESPDISP_DEVELOPMENT_TEAM="YSHQQLS73U"
# Personal teams cannot sign System Extensions; a paid team enables it.
ESPDISP_CAMERA_EXTENSION=$([[ "$ESPDISP_DEVELOPMENT_TEAM" == "YSHQQLS73U" ]] && echo 0 || echo 1)
