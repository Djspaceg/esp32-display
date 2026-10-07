// Engine globals renamed so they can share one image with Doom.
//
// The P4 image links both engines, and both come from id's code: these names
// are defined by Doom's unity build too (firmware/doom/src), so linking them
// twice fails. Renaming the Quake side through the preprocessor leaves the
// vendored sources unedited. Every Quake engine unit includes this before its
// source (platform/quake_prelude.h). Found by intersecting the global symbols
// of both engines' objects; a new clash fails the link with a duplicate
// definition, which is the cue to add it here.
#pragma once

#define M_Init quake_M_Init
#define R_DrawSprite quake_R_DrawSprite
#define R_Init quake_R_Init
#define R_InitTextures quake_R_InitTextures
#define R_SetupFrame quake_R_SetupFrame
#define S_Init quake_S_Init
#define S_Shutdown quake_S_Shutdown
#define S_StartSound quake_S_StartSound
#define S_StopSound quake_S_StopSound
#define V_Init quake_V_Init
#define WritePCXfile quake_WritePCXfile
#define Z_CheckHeap quake_Z_CheckHeap
#define Z_ClearZone quake_Z_ClearZone
#define Z_Free quake_Z_Free
#define Z_Malloc quake_Z_Malloc
#define deathmatch quake_deathmatch
#define gammatable quake_gammatable
#define mainzone quake_mainzone
#define nomonsters quake_nomonsters
#define onground quake_onground
#define startepisode quake_startepisode
#define timelimit quake_timelimit
