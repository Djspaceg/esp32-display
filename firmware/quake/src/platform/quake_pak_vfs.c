// The read-only Quake data files: /qdata/id1/pak0.pak, and pak1.pak and on
// where the Mac app stored them, served from the game data area with
// esp_partition_read().
//
// The area (doom/src/game_store.h) is the P4's quake_pak partition, and on an
// S3 the raw flash past its 8 MiB table. A legacy area holds pak0.pak alone,
// raw at offset 0; one with a game store directory names each pak's offset and
// length. Quake opens pak0.pak, pak1.pak, ... until one is missing, so the
// paks it is given run from slot 0 without a gap.
//
// Quake reads its pack through both of its file paths: Sys_FileOpenRead and
// friends for the pack directory and every whole-file load, and stdio
// (fopen/fseek/fread) for demos. One VFS registration serves both unchanged.
// Nothing maps the partition, which matters: it crosses 16 MiB, past what this
// core's flash cache can map.
//
// Flash reads run with the cache disabled, so they must not run on a stack in
// PSRAM, which the Quake task's is (quake_mode.cpp). Every partition read in a
// Quake boot is therefore handed to a small reader task whose stack is in
// internal RAM, and the Quake task waits for it. (IDF's shared-stack call was
// the lighter option, but it moves the task's FPU save area onto the borrowed
// stack, and Quake's task uses the FPU.)
//
// The structural checks and the read/seek arithmetic are in quake_pak_model.h
// and host tested.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)

#include "quake_pak_vfs.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>

#include <esp_flash.h>
#include <esp_heap_caps.h>
#include <esp_partition.h>
#include <esp_vfs.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include <game_store.h>

#include "quake_pak_model.h"
#include "quake_platform.h"

// The reader task: enough for esp_partition_read() and the flash driver below
// it. Above the Quake task's priority, so a read starts as soon as it is asked.
#define QUAKE_PAK_READ_STACK_BYTES 4096
#define QUAKE_PAK_READ_PRIORITY 2

// Open handles at once. Quake holds the pack open for the whole session and
// opens it once more per demo it plays.
#define QUAKE_PAK_MAX_OPEN 4

static const esp_partition_t* s_partition = NULL;
static const char* s_failure = "not checked";

// Each pak Quake is given: where it starts in the area and, once checked, its
// length.
static quake_pak_span_t s_paks[GAME_STORE_MAX_QUAKE_SLOT + 1];
static int s_pak_count = 0;

static struct {
  bool open;
  int slot;
  uint32_t position;
} s_files[QUAKE_PAK_MAX_OPEN];

// One read at a time: s_args_lock owns the request block below from setting
// it to reading the result; s_request starts the reader, s_done ends the wait.
static SemaphoreHandle_t s_args_lock = NULL;
static SemaphoreHandle_t s_request = NULL;
static SemaphoreHandle_t s_done = NULL;
static uint32_t s_read_offset;
static void* s_read_out;
static uint32_t s_read_length;
static esp_err_t s_read_result;

static void quake_pak_reader_task(void* arg) {
  (void)arg;
  while (true) {
    xSemaphoreTake(s_request, portMAX_DELAY);
    s_read_result = esp_partition_read(s_partition, s_read_offset, s_read_out,
                                       s_read_length);
    xSemaphoreGive(s_done);
  }
}

// `context` is the pak; `offset` is within it.
static bool quake_pak_read(void* context, uint32_t offset, void* out,
                           uint32_t length) {
  const quake_pak_span_t* pak = (const quake_pak_span_t*)context;
  if (offset > pak->bytes || length > pak->bytes - offset) return false;
  offset += pak->base;
  if (s_args_lock == NULL) {
    // Not mounted yet: the normal firmware's preflight, on loopTask, whose
    // stack is internal.
    return esp_partition_read(s_partition, offset, out, length) == ESP_OK;
  }
  xSemaphoreTake(s_args_lock, portMAX_DELAY);
  s_read_offset = offset;
  s_read_out = out;
  s_read_length = length;
  s_read_result = ESP_FAIL;
  xSemaphoreGive(s_request);
  xSemaphoreTake(s_done, portMAX_DELAY);
  const bool ok = s_read_result == ESP_OK;
  xSemaphoreGive(s_args_lock);
  return ok;
}


const char* quake_pak_preflight(void) {
  s_pak_count = 0;
  s_failure = game_store_open();
  if (s_failure != NULL) return s_failure;
  s_partition = game_store_partition();
  const game_store_t* store = game_store_directory();
  quake_pak_span_t spans[GAME_STORE_MAX_QUAKE_SLOT + 1];
  const int count = quake_pak_spans(store, spans, &s_failure);
  if (count == 0) return s_failure;
  static const char* const kSlotFailures[] = {
      "pak0.pak is unusable", "pak1.pak is unusable", "pak2.pak is unusable",
      "pak3.pak is unusable", "pak4.pak is unusable", "pak5.pak is unusable",
      "pak6.pak is unusable", "pak7.pak is unusable", "pak8.pak is unusable",
      "pak9.pak is unusable"};
  for (int slot = 0; slot < count; ++slot) {
    quake_pak_span_t pak = spans[slot];
    uint32_t pack_bytes = 0;
    const char* problem =
        quake_pak_check(quake_pak_read, &pak, pak.bytes, &pack_bytes);
    if (problem != NULL) {
      // A legacy area keeps the check's own words, which the app and the CLI
      // name; a stored pak says which one it was.
      s_failure = store->legacy ? problem : kSlotFailures[slot];
      quake_log("pak%d.pak refused: %s", slot, problem);
      return s_failure;
    }
    pak.bytes = pack_bytes;
    s_paks[slot] = pak;
  }
  s_pak_count = count;
  return NULL;
}

uint32_t quake_pak_bytes(void) {
  return s_pak_count > 0 ? s_paks[0].bytes : 0;
}

static int quake_pak_vfs_open(const char* path, int flags, int mode) {
  (void)mode;
  const int slot = quake_pak_path_slot(path);
  if (slot < 0 || slot >= s_pak_count) {
    errno = ENOENT;
    return -1;
  }
  if ((flags & O_ACCMODE) != O_RDONLY) {
    // Saves and config.cfg: Quake reports the failure and carries on.
    errno = EROFS;
    return -1;
  }
  for (int fd = 0; fd < QUAKE_PAK_MAX_OPEN; ++fd) {
    if (!s_files[fd].open) {
      s_files[fd].open = true;
      s_files[fd].slot = slot;
      s_files[fd].position = 0;
      return fd;
    }
  }
  errno = ENFILE;
  return -1;
}

static bool quake_pak_fd_valid(int fd) {
  return fd >= 0 && fd < QUAKE_PAK_MAX_OPEN && s_files[fd].open;
}

static ssize_t quake_pak_vfs_read(int fd, void* dst, size_t size) {
  if (!quake_pak_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  quake_pak_span_t* pak = &s_paks[s_files[fd].slot];
  const uint32_t length =
      quake_pak_read_length(s_files[fd].position, pak->bytes, size);
  if (length == 0) return 0;
  if (!quake_pak_read(pak, s_files[fd].position, dst, length)) {
    errno = EIO;
    return -1;
  }
  s_files[fd].position += length;
  return (ssize_t)length;
}

static off_t quake_pak_vfs_lseek(int fd, off_t offset, int whence) {
  if (!quake_pak_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  const int64_t target =
      quake_pak_seek(s_files[fd].position, s_paks[s_files[fd].slot].bytes,
                     offset, whence);
  if (target < 0) {
    errno = EINVAL;
    return -1;
  }
  s_files[fd].position = (uint32_t)target;
  return (off_t)target;
}

static int quake_pak_vfs_close(int fd) {
  if (!quake_pak_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  s_files[fd].open = false;
  return 0;
}

static int quake_pak_vfs_fstat(int fd, struct stat* st) {
  if (!quake_pak_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  memset(st, 0, sizeof(*st));
  st->st_mode = S_IFREG | 0444;
  st->st_size = s_paks[s_files[fd].slot].bytes;
  return 0;
}

static int quake_pak_vfs_stat(const char* path, struct stat* st) {
  const int slot = quake_pak_path_slot(path);
  if (slot < 0 || slot >= s_pak_count) {
    errno = ENOENT;
    return -1;
  }
  memset(st, 0, sizeof(*st));
  st->st_mode = S_IFREG | 0444;
  st->st_size = s_paks[slot].bytes;
  return 0;
}

const char* quake_pak_mount(void) {
  if (quake_pak_preflight() != NULL) return s_failure;
  SemaphoreHandle_t args_lock = xSemaphoreCreateMutex();
  s_request = xSemaphoreCreateBinary();
  s_done = xSemaphoreCreateBinary();
  // xTaskCreate puts the stack in internal RAM.
  if (args_lock == NULL || s_request == NULL || s_done == NULL ||
      xTaskCreatePinnedToCore(quake_pak_reader_task, "quake_pak",
                              QUAKE_PAK_READ_STACK_BYTES, NULL,
                              QUAKE_PAK_READ_PRIORITY, NULL,
                              tskNO_AFFINITY) != pdPASS) {
    s_failure = "no internal RAM for the pak reader";
    return s_failure;
  }
  // Last: from here on every read goes through the reader task.
  s_args_lock = args_lock;
  memset(s_files, 0, sizeof(s_files));
  static const esp_vfs_t vfs = {
      .flags = ESP_VFS_FLAG_DEFAULT | ESP_VFS_FLAG_READONLY_FS,
      .read = &quake_pak_vfs_read,
      .lseek = &quake_pak_vfs_lseek,
      .open = &quake_pak_vfs_open,
      .close = &quake_pak_vfs_close,
      .fstat = &quake_pak_vfs_fstat,
      .stat = &quake_pak_vfs_stat,
  };
  if (esp_vfs_register(QUAKE_PAK_MOUNT, &vfs, NULL) != ESP_OK) {
    s_failure = "could not register the /qdata file system";
    return s_failure;
  }
  return NULL;
}

const char* quake_pak_failure(void) { return s_failure; }

#endif  // ESPDISP_QUAKE_RUNTIME
