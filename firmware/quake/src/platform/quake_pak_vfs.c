// The read-only Quake data file: /qdata/id1/pak0.pak, served from the
// quake_pak partition with esp_partition_read().
//
// On the P4 the partition is in the table (partitions_p4_4b.csv). The S3's
// universal table covers only its common 8 MiB, so there the pak is a raw
// flash region past it, registered at runtime as an external partition, and
// only on a chip big enough to hold it: 32 MiB in practice.
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

#include "quake_pak_model.h"

// The partition's identity in partitions_p4_4b.csv; tools/espdisp.py checks
// the same pair before `write-data quake_pak` writes anything.
#define QUAKE_PAK_PARTITION_TYPE 0x42
#define QUAKE_PAK_PARTITION_SUBTYPE 0x07

#if CONFIG_IDF_TARGET_ESP32S3
// The S3 region: from the end of the universal 8 MiB layout, 18 MiB, so the
// chip must have 26 MiB. tools/espdisp.py writes the bundle's pak here, and
// only to a chip that large (QUAKE_PAK_S3_* there).
#define QUAKE_PAK_S3_OFFSET 0x800000u
#define QUAKE_PAK_S3_BYTES 0x1200000u
#endif

// The reader task: enough for esp_partition_read() and the flash driver below
// it. Above the Quake task's priority, so a read starts as soon as it is asked.
#define QUAKE_PAK_READ_STACK_BYTES 4096
#define QUAKE_PAK_READ_PRIORITY 2

// Open handles at once. Quake holds the pack open for the whole session and
// opens it once more per demo it plays.
#define QUAKE_PAK_MAX_OPEN 4

static const esp_partition_t* s_partition = NULL;
static uint32_t s_pack_bytes = 0;
static const char* s_failure = "not checked";

static struct {
  bool open;
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

static bool quake_pak_read(void* context, uint32_t offset, void* out,
                           uint32_t length) {
  (void)context;
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

#if CONFIG_IDF_TARGET_ESP32S3
// Registers the S3 region as the quake_pak partition, once per boot. NULL on
// success, else why the chip cannot hold it.
static const char* quake_pak_register_s3_region(void) {
  static const char* s_region_failure = "not registered";
  static bool s_tried = false;
  if (s_tried) return s_region_failure;
  s_tried = true;
  uint32_t physical = 0;
  if (esp_flash_get_physical_size(esp_flash_default_chip, &physical) !=
      ESP_OK) {
    s_region_failure = "could not read the flash size";
    return s_region_failure;
  }
  if (physical < QUAKE_PAK_S3_OFFSET + QUAKE_PAK_S3_BYTES) {
    s_region_failure = "flash too small for Quake's data (needs 32 MiB)";
    return s_region_failure;
  }
  // The driver takes its size from the image header, 8 MiB, and refuses to
  // register a partition past it; the chip is bigger, so tell it. Reads past
  // 16 MiB need the chip driver's 4-byte addressing (SPI_FLASH_CHIP_CAP_32MB_
  // SUPPORT); the pak's own check below fails cleanly if they come back wrong.
  if (esp_flash_default_chip->size < physical) {
    esp_flash_default_chip->size = physical;
  }
  if (esp_partition_register_external(
          esp_flash_default_chip, QUAKE_PAK_S3_OFFSET, QUAKE_PAK_S3_BYTES,
          "quake_pak", (esp_partition_type_t)QUAKE_PAK_PARTITION_TYPE,
          (esp_partition_subtype_t)QUAKE_PAK_PARTITION_SUBTYPE,
          NULL) != ESP_OK) {
    s_region_failure = "could not register the Quake data region";
    return s_region_failure;
  }
  s_region_failure = NULL;
  return NULL;
}
#endif

const char* quake_pak_preflight(void) {
  s_pack_bytes = 0;
#if CONFIG_IDF_TARGET_ESP32S3
  s_failure = quake_pak_register_s3_region();
  if (s_failure != NULL) return s_failure;
#endif
  s_partition = esp_partition_find_first(
      (esp_partition_type_t)QUAKE_PAK_PARTITION_TYPE,
      (esp_partition_subtype_t)QUAKE_PAK_PARTITION_SUBTYPE, "quake_pak");
  if (s_partition == NULL) {
    s_failure =
        "no quake_pak partition (flash the current P4 bundle over USB)";
    return s_failure;
  }
  s_failure = quake_pak_check(quake_pak_read, NULL, s_partition->size,
                              &s_pack_bytes);
  return s_failure;
}

uint32_t quake_pak_bytes(void) { return s_pack_bytes; }

static int quake_pak_vfs_open(const char* path, int flags, int mode) {
  (void)mode;
  if (!quake_pak_path_matches(path)) {
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
  const uint32_t length =
      quake_pak_read_length(s_files[fd].position, s_pack_bytes, size);
  if (length == 0) return 0;
  if (!quake_pak_read(NULL, s_files[fd].position, dst, length)) {
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
      quake_pak_seek(s_files[fd].position, s_pack_bytes, offset, whence);
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
  st->st_size = s_pack_bytes;
  return 0;
}

static int quake_pak_vfs_stat(const char* path, struct stat* st) {
  if (!quake_pak_path_matches(path)) {
    errno = ENOENT;
    return -1;
  }
  memset(st, 0, sizeof(*st));
  st->st_mode = S_IFREG | 0444;
  st->st_size = s_pack_bytes;
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
