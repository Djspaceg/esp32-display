#include <stdio.h>

#include "m_argv.h"

#include "doomgeneric.h"

#if defined(CONFIG_IDF_TARGET_ESP32S3) || defined(ESP_PLATFORM)
// On ESP32, DG_ScreenBuffer is allocated in PSRAM by DG_Init()
// (in doomgeneric_esp32s3.c). We just declare the extern here.
#else
pixel_t* DG_ScreenBuffer = NULL;
#endif

void M_FindResponseFile(void);
void D_DoomMain (void);


void doomgeneric_Create(int argc, char **argv)
{
	// save arguments
    myargc = argc;
    myargv = argv;

	M_FindResponseFile();

#if !defined(CONFIG_IDF_TARGET_ESP32S3) && !defined(ESP_PLATFORM)
	DG_ScreenBuffer = malloc(DOOMGENERIC_RESX * DOOMGENERIC_RESY * 4);
#endif

	DG_Init();

	D_DoomMain ();
}

