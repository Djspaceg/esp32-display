// The engine's system and video layer on the P4: what upstream's sys_null.c,
// vid_null.c and quakegeneric.c provide on a desktop.
//
// Compiled as C beside the engine, after the same prelude as every engine unit
// (relocations and renames), so it sees the engine's globals as they really
// are. Hardware is reached only through quake_platform.h.
//
// GPL-2.0, like the engine it is adapted from.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)

#include "quake_prelude.h"

#include "../engine/quakedef.h"
#include "../engine/d_local.h"
#include "../engine/quakegeneric.h"

#include <errno.h>

#include <esp_heap_caps.h>
#include <esp_memory_utils.h>
#include <esp_timer.h>

#include "quake_platform.h"
#include "quake_pak_model.h"

qboolean isDedicated;

// ---- Relocated engine arrays (quake_statics.h) ----------------------------

void* quake_statics_calloc(unsigned bytes, quake_static_placement_t placement) {
  if (placement == QUAKE_STATIC_INTERNAL) {
    void* p = heap_caps_calloc(1, bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (p != NULL) return p;
  }
  return heap_caps_calloc(1, bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
}

bool quake_statics_allocate(void) {
  bool ok = true;
#define QUAKE_ALLOCATE_UNIT(unit) ok = quake_statics_allocate_##unit() && ok;
  QUAKE_STATICS_UNITS(QUAKE_ALLOCATE_UNIT)
#undef QUAKE_ALLOCATE_UNIT
  return ok;
}

// ---- Files ------------------------------------------------------------------
//
// Upstream's stdio versions. /qdata is the read-only partition file system
// (quake_pak_vfs.c), so writes fail and Quake reports it: saves and
// config.cfg are off until there is a writable store.

#define MAX_HANDLES 10
static FILE* sys_handles[MAX_HANDLES];

static int findhandle(void) {
  for (int i = 1; i < MAX_HANDLES; i++) {
    if (!sys_handles[i]) return i;
  }
  Sys_Error("out of handles");
  return -1;
}

static int filelength(FILE* f) {
  const long pos = ftell(f);
  fseek(f, 0, SEEK_END);
  const long end = ftell(f);
  fseek(f, pos, SEEK_SET);
  return (int)end;
}

int Sys_FileOpenRead(char* path, int* hndl) {
  const int i = findhandle();
  FILE* f = fopen(path, "rb");
  if (!f) {
    *hndl = -1;
    return -1;
  }
  sys_handles[i] = f;
  *hndl = i;
  return filelength(f);
}

int Sys_FileOpenWrite(char* path) {
  // Upstream treats this as fatal; here it is expected (nothing is writable),
  // and COM_WriteFile reports a -1 and carries on.
  const int i = findhandle();
  FILE* f = fopen(path, "wb");
  if (!f) {
    Con_Printf("Cannot write %s: saving is not available on this board\n",
               path);
    return -1;
  }
  sys_handles[i] = f;
  return i;
}

void Sys_FileClose(int handle) {
  if (handle <= 0 || handle >= MAX_HANDLES || !sys_handles[handle]) return;
  fclose(sys_handles[handle]);
  sys_handles[handle] = NULL;
}

void Sys_FileSeek(int handle, int position) {
  fseek(sys_handles[handle], position, SEEK_SET);
}

int Sys_FileRead(int handle, void* dest, int count) {
  return (int)fread(dest, 1, count, sys_handles[handle]);
}

int Sys_FileWrite(int handle, void* data, int count) {
  return (int)fwrite(data, 1, count, sys_handles[handle]);
}

int Sys_FileTime(char* path) {
  FILE* f = fopen(path, "rb");
  if (f) {
    fclose(f);
    return 1;
  }
  return -1;
}

void Sys_mkdir(char* path) { (void)path; }

// ---- System -----------------------------------------------------------------

void Sys_MakeCodeWriteable(unsigned long startaddr, unsigned long length) {
  (void)startaddr;
  (void)length;
}

// Both buffers below are on the Quake task's stack, which is in PSRAM and
// large: a static one would cost the streaming firmware its internal RAM.
void Sys_Error(char* error, ...) {
  char reason[160];
  va_list args;
  va_start(args, error);
  vsnprintf(reason, sizeof(reason), error, args);
  va_end(args);
  // Engine messages often end in a newline; the failure card wraps its own.
  size_t len = strlen(reason);
  while (len > 0 && (reason[len - 1] == '\n' || reason[len - 1] == '\r')) {
    reason[--len] = '\0';
  }
  quake_fail_restart(reason, true);
}

void Sys_Printf(char* fmt, ...) {
  char text[1024];
  va_list args;
  va_start(args, fmt);
  vsnprintf(text, sizeof(text), fmt, args);
  va_end(args);
  quake_console_write(text);
}

void Sys_Quit(void) { quake_quit(); }

double Sys_FloatTime(void) {
  // Quake keeps realtime as a double that only grows; microseconds since boot
  // fit a double exactly for longer than any session.
  return (double)esp_timer_get_time() / 1000000.0;
}

char* Sys_ConsoleInput(void) { return (char*)quake_console_read_line(); }

void Sys_Sleep(void) {}
void Sys_SendKeyEvents(void) {}
void Sys_HighFPPrecision(void) {}
void Sys_LowFPPrecision(void) {}

// ---- Video ------------------------------------------------------------------
//
// Upstream's vid_null.c with its buffers allocated instead of static, and a
// palette kept as big-endian RGB565 for the panel.

viddef_t vid;

#define BASEWIDTH QUAKEGENERIC_RES_X
#define BASEHEIGHT QUAKEGENERIC_RES_Y

static byte* vid_buffer;
static short* zbuffer;
static byte* surfcache;
// Read per pixel by the scaler: internal RAM, allocated by VID_Init.
static uint16_t* palette565;

static void* quake_alloc_prefer_internal(size_t bytes) {
  void* p = heap_caps_malloc(bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  return p != NULL ? p : heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
}

static const char* quake_where(const void* p) {
  return esp_ptr_external_ram(p) ? "PSRAM" : "internal";
}

void VID_SetPalette(unsigned char* palette) {
  for (int i = 0; i < 256; i++) {
    const unsigned r = palette[i * 3 + 0];
    const unsigned g = palette[i * 3 + 1];
    const unsigned b = palette[i * 3 + 2];
    const uint16_t rgb565 =
        (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
    // Panel byte order, as Doom's frame path writes it.
    palette565[i] = __builtin_bswap16(rgb565);
  }
}

void VID_ShiftPalette(unsigned char* palette) { VID_SetPalette(palette); }

void VID_Init(unsigned char* palette) {
  vid.maxwarpwidth = vid.width = vid.conwidth = BASEWIDTH;
  vid.maxwarpheight = vid.height = vid.conheight = BASEHEIGHT;
  vid.aspect = 1.0;
  vid.numpages = 1;
  vid.colormap = host_colormap;
  vid.fullbright = 256 - LittleLong(*((int*)vid.colormap + 2048));
  vid.rowbytes = vid.conrowbytes = BASEWIDTH;

  // The frame and depth buffer are touched for every pixel drawn; internal
  // RAM when the Quake boot has room for them, which it should.
  vid_buffer = (byte*)quake_alloc_prefer_internal(BASEWIDTH * BASEHEIGHT);
  zbuffer = (short*)quake_alloc_prefer_internal(
      BASEWIDTH * BASEHEIGHT * sizeof(short));
  const int surfcache_size = D_SurfaceCacheForRes(BASEWIDTH, BASEHEIGHT);
  surfcache = (byte*)heap_caps_malloc(surfcache_size,
                                      MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (vid_buffer == NULL || zbuffer == NULL || surfcache == NULL) {
    Sys_Error("no memory for the %dx%d frame", BASEWIDTH, BASEHEIGHT);
  }
  quake_log("frame %s, depth %s, %d KB surface cache %s",
            quake_where(vid_buffer), quake_where(zbuffer),
            surfcache_size / 1024, quake_where(surfcache));

  palette565 = (uint16_t*)quake_alloc_prefer_internal(256 * sizeof(uint16_t));
  if (palette565 == NULL) Sys_Error("no memory for the palette");
  vid.buffer = vid.conbuffer = vid_buffer;
  d_pzbuffer = zbuffer;
  D_InitCaches(surfcache, surfcache_size);
  VID_SetPalette(palette);
}

void VID_Shutdown(void) {}

static uint32_t frames_rendered;

void VID_Update(vrect_t* rects) {
  (void)rects;
  ++frames_rendered;
  quake_display_present(vid.buffer, palette565);
}

void D_BeginDirectRect(int x, int y, byte* pbitmap, int width, int height) {
  (void)x; (void)y; (void)pbitmap; (void)width; (void)height;
}

void D_EndDirectRect(int x, int y, int width, int height) {
  (void)x; (void)y; (void)width; (void)height;
}

// ---- quakegeneric callbacks (in_null.c) -----------------------------------

int QG_GetKey(int* down, int* key) { return quake_input_get_key(down, key); }

void QG_GetMouseMove(int* x, int* y) { quake_input_get_mouse(x, y); }

void QG_GetJoyAxes(float* axes) {
  for (int i = 0; i < QUAKEGENERIC_JOY_MAX_AXES; i++) axes[i] = 0.0f;
}

void QG_Init(void) {}
void QG_Quit(void) {}
void QG_DrawFrame(void* pixels) { (void)pixels; }
void QG_SetPalette(unsigned char palette[768]) { (void)palette; }

// ---- Host -------------------------------------------------------------------

static double s_last_time;

const char* quake_engine_start(int argc, char** argv, uint32_t hunk_bytes,
                               uint32_t reserve_bytes) {
  if (!quake_statics_allocate()) return "no memory for the engine's tables";
  // As much of hunk_bytes as PSRAM has once reserve_bytes is kept back; the
  // engine refuses a heap under its floor itself, with the sizes.
  const size_t largest =
      heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (largest <= reserve_bytes) return "no PSRAM for the engine heap";
  if (largest - reserve_bytes < hunk_bytes) {
    hunk_bytes = (uint32_t)((largest - reserve_bytes) & ~(size_t)0xFFFF);
  }
  static quakeparms_t parms;
  parms.memsize = (int)hunk_bytes;
  parms.membase =
      heap_caps_malloc(hunk_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (parms.membase == NULL) return "no PSRAM for the engine heap";
  quake_log("engine heap %u KB", (unsigned)(hunk_bytes / 1024));
  parms.basedir = QUAKE_PAK_MOUNT;
  parms.cachedir = NULL;

  COM_InitArgv(argc, argv);
  parms.argc = com_argc;
  parms.argv = com_argv;

  // A failure inside ends in Sys_Error, which restarts with the reason.
  Host_Init(&parms);
  s_last_time = Sys_FloatTime();
  return NULL;
}

void quake_engine_frame(void) {
  const double now = Sys_FloatTime();
  const double elapsed = now - s_last_time;
  s_last_time = now;
  Host_Frame((float)elapsed);
}

bool quake_engine_in_menu(void) {
  // con_forcedup: disconnected with no demo, where keys go to the console even
  // though key_dest still says game.
  return key_dest != key_game || con_forcedup;
}

void quake_engine_command(const char* text) { Cbuf_AddText((char*)text); }

uint32_t quake_engine_frames_rendered(void) { return frames_rendered; }

#endif  // ESPDISP_QUAKE_RUNTIME
