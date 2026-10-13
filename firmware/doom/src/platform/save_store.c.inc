// The saved-games store on the board: where its area is, flash access from
// any task, compression, and the /save file system Doom writes through.
//
// The area is the 60 KB (0xF000) every S3 and P4 partition table leaves
// unused beside doom_wad: on an S3 the gap before it (0x3F0000, after app1),
// on a P4 the gap after it (0xDF1000, before quake_pak). Nothing writes or
// erases it: OTA updates write their app slot, USB flashes write the parts a
// bundle names, and the Mac app writes the game store. It is registered here
// as an external partition, which the driver refuses if it would overlap any
// other, so a table without the gap simply has no store.
//
// Files are compressed with the ROM's deflate (miniz): Quake's text saves
// shrink several times over, which is what makes room for them.
//
// Flash access runs with the cache disabled, so not on a PSRAM stack, which
// the Quake task's is. Any flash operation asked for from one is handed to a
// small worker task with an internal stack, as the pak reader does.
//
// Part of the Doom unity build; the Quake boot reaches it through
// save_store.h.
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#include <esp_heap_caps.h>
#include <esp_memory_utils.h>
#include <esp_partition.h>
#include <esp_vfs.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include <miniz.h>

#include "../save_store.h"

#define SAVE_AREA_BYTES 0xF000u
#define SAVE_AREA_TYPE 0x42
#define SAVE_AREA_SUBTYPE 0x08
#define SAVE_AREA_LABEL "game_saves"
#define SAVE_WAD_SUBTYPE 0x06
#define SAVE_FILE_MAX_OPEN 4
// Bigger than any save either game writes (Doom's vanilla limit is 180 KB).
#define SAVE_FILE_MAX_BYTES (1u << 20)
#define SAVE_WORKER_STACK_BYTES 4096
#define SAVE_WORKER_PRIORITY 2

// From doom_hw_bridge.cpp: one "[save] " line on Serial, from any task.
void save_store_log_line(const char* line);

static void save_log(const char* format, ...)
    __attribute__((format(printf, 1, 2)));
static void save_log(const char* format, ...) {
  char line[160];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  save_store_log_line(line);
}

static bool save_tried = false;
static const char* save_failure = "save store not opened";
static const esp_partition_t* save_area = NULL;
// In PSRAM, allocated at open: nothing of the store is paid for in a
// streaming boot's internal RAM.
static save_store_t* save_state = NULL;
static SemaphoreHandle_t save_lock = NULL;
// Heads of files that could not be read this boot: never written over, so a
// game that fell back to its defaults does not replace the file it lost.
static uint32_t save_unreadable = 0;

// ---- Flash, from any stack --------------------------------------------------

enum { SAVE_OP_READ, SAVE_OP_WRITE, SAVE_OP_ERASE };

static SemaphoreHandle_t save_request = NULL;
static SemaphoreHandle_t save_done = NULL;
static bool save_worker_started = false;
static struct {
  int op;
  uint32_t offset;
  void* data;
  uint32_t length;
  esp_err_t result;
} save_job;

static esp_err_t save_flash_now(int op, uint32_t offset, void* data,
                                uint32_t length) {
  switch (op) {
    case SAVE_OP_READ:
      return esp_partition_read(save_area, offset, data, length);
    case SAVE_OP_WRITE:
      return esp_partition_write(save_area, offset, data, length);
    default:
      return esp_partition_erase_range(save_area, offset, length);
  }
}

static void save_worker_task(void* arg) {
  (void)arg;
  while (true) {
    xSemaphoreTake(save_request, portMAX_DELAY);
    save_job.result = save_flash_now(save_job.op, save_job.offset,
                                     save_job.data, save_job.length);
    xSemaphoreGive(save_done);
  }
}

// Callers hold save_lock, which also owns save_job. The worker is started on
// the first call from a PSRAM stack (Quake's); Doom's loop never needs it.
static bool save_flash(int op, uint32_t offset, void* data, uint32_t length) {
  if (!esp_ptr_external_ram(__builtin_frame_address(0))) {
    return save_flash_now(op, offset, data, length) == ESP_OK;
  }
  if (!save_worker_started) {
    // xTaskCreate puts the stack in internal RAM.
    if (save_request == NULL) save_request = xSemaphoreCreateBinary();
    if (save_done == NULL) save_done = xSemaphoreCreateBinary();
    if (save_request == NULL || save_done == NULL ||
        xTaskCreatePinnedToCore(save_worker_task, "game_saves",
                                SAVE_WORKER_STACK_BYTES, NULL,
                                SAVE_WORKER_PRIORITY, NULL,
                                tskNO_AFFINITY) != pdPASS) {
      save_log("no internal RAM for the save worker");
      return false;
    }
    save_worker_started = true;
  }
  save_job.op = op;
  save_job.offset = offset;
  save_job.data = data;
  save_job.length = length;
  save_job.result = ESP_FAIL;
  xSemaphoreGive(save_request);
  xSemaphoreTake(save_done, portMAX_DELAY);
  return save_job.result == ESP_OK;
}

static bool save_area_read(void* context, uint32_t offset, void* out,
                           uint32_t length) {
  (void)context;
  return save_flash(SAVE_OP_READ, offset, out, length);
}

static bool save_area_write(void* context, uint32_t offset, const void* data,
                            uint32_t length) {
  (void)context;
  return save_flash(SAVE_OP_WRITE, offset, (void*)data, length);
}

static bool save_area_erase(void* context, uint32_t sector) {
  (void)context;
  return save_flash(SAVE_OP_ERASE, sector * SAVE_STORE_SECTOR_BYTES, NULL,
                    SAVE_STORE_SECTOR_BYTES);
}

// ---- Opening ----------------------------------------------------------------

static const char* save_register_area(void) {
  const esp_partition_t* wad = esp_partition_find_first(
      (esp_partition_type_t)SAVE_AREA_TYPE,
      (esp_partition_subtype_t)SAVE_WAD_SUBTYPE, NULL);
  if (wad == NULL) return "no doom_wad partition to find the save area by";
  // Before doom_wad (the S3 tables), else after it (the P4's).
  const uint32_t candidates[2] = {
      wad->address >= SAVE_AREA_BYTES ? wad->address - SAVE_AREA_BYTES : 0,
      wad->address + wad->size};
  for (int i = 0; i < 2; ++i) {
    if (candidates[i] == 0 || candidates[i] % SAVE_STORE_SECTOR_BYTES != 0) {
      continue;
    }
    if (esp_partition_register_external(
            esp_flash_default_chip, candidates[i], SAVE_AREA_BYTES,
            SAVE_AREA_LABEL, (esp_partition_type_t)SAVE_AREA_TYPE,
            (esp_partition_subtype_t)SAVE_AREA_SUBTYPE,
            &save_area) == ESP_OK) {
      return NULL;
    }
  }
  return "no free 60 KB beside doom_wad for saves";
}

// ---- Compression ------------------------------------------------------------

// PSRAM only: a game boot has megabytes of it, and internal RAM is the
// panel's and the flash driver's.
static void* save_alloc(size_t bytes) {
  return heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
}

// Deflates `length` bytes into a new buffer; NULL when it does not shrink.
static uint8_t* save_deflate(const uint8_t* in, uint32_t length,
                             uint32_t* out_length) {
  if (length < 64) return NULL;
  tdefl_compressor* c = (tdefl_compressor*)save_alloc(sizeof(*c));
  uint8_t* out = (uint8_t*)save_alloc(length);
  if (c == NULL || out == NULL) {
    free(c);
    free(out);
    return NULL;
  }
  size_t in_size = length;
  size_t out_size = length;
  tdefl_status status = TDEFL_STATUS_BAD_PARAM;
  if (tdefl_init(c, NULL, NULL, TDEFL_DEFAULT_MAX_PROBES) ==
      TDEFL_STATUS_OKAY) {
    status = tdefl_compress(c, in, &in_size, out, &out_size, TDEFL_FINISH);
  }
  free(c);
  if (status != TDEFL_STATUS_DONE || in_size != length) {
    free(out);
    return NULL;
  }
  *out_length = (uint32_t)out_size;
  return out;
}

static bool save_inflate(const uint8_t* in, uint32_t length, uint8_t* out,
                         uint32_t out_length) {
  tinfl_decompressor* d = (tinfl_decompressor*)save_alloc(sizeof(*d));
  if (d == NULL) return false;
  tinfl_init(d);
  size_t in_size = length;
  size_t out_size = out_length;
  const tinfl_status status =
      tinfl_decompress(d, in, &in_size, out, out, &out_size,
                       TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
  free(d);
  return status == TINFL_STATUS_DONE && out_size == out_length;
}

// ---- Files ------------------------------------------------------------------

static struct {
  bool open;
  bool writable;
  bool append;
  bool dirty;
  bool failed;  // a write failed: the file is not stored on close
  char name[SAVE_STORE_NAME_BYTES];
  uint8_t* data;
  uint32_t length;
  uint32_t capacity;
  uint32_t position;
} save_files[SAVE_FILE_MAX_OPEN];

static bool save_fd_valid(int fd) {
  return fd >= 0 && fd < SAVE_FILE_MAX_OPEN && save_files[fd].open;
}

// File `index`'s raw bytes into a new buffer of at least one byte.
static uint8_t* save_load(int index, uint32_t* length) {
  const save_store_file_t* file = &save_state->files[index];
  uint8_t* stored = (uint8_t*)save_alloc(file->stored_bytes + 1);
  if (stored == NULL) return NULL;
  if (!save_store_read(save_state, index, 0, stored, file->stored_bytes)) {
    free(stored);
    return NULL;
  }
  uint8_t* raw = stored;
  if (file->encoding == SAVE_STORE_ENCODING_DEFLATE) {
    raw = (uint8_t*)save_alloc(file->raw_bytes + 1);
    if (raw == NULL ||
        !save_inflate(stored, file->stored_bytes, raw, file->raw_bytes)) {
      free(raw);
      free(stored);
      return NULL;
    }
    free(stored);
  }
  if (save_store_crc32(0, raw, file->raw_bytes) != file->raw_crc) {
    free(raw);
    return NULL;
  }
  *length = file->raw_bytes;
  return raw;
}

bool save_store_ready(void) { return save_tried && save_failure == NULL; }

int save_file_open(const char* name, int flags) {
  if (!save_store_ready()) {
    errno = ENODEV;
    return -1;
  }
  if (!save_store_name_valid(name)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  xSemaphoreTake(save_lock, portMAX_DELAY);
  int fd = 0;
  while (fd < SAVE_FILE_MAX_OPEN && save_files[fd].open) ++fd;
  if (fd == SAVE_FILE_MAX_OPEN) {
    xSemaphoreGive(save_lock);
    errno = ENFILE;
    return -1;
  }
  const int access = flags & O_ACCMODE;
  const int index = save_store_find(save_state, name);
  if (index < 0 && (access == O_RDONLY || !(flags & O_CREAT))) {
    xSemaphoreGive(save_lock);
    errno = ENOENT;
    return -1;
  }
  uint8_t* data = NULL;
  uint32_t length = 0;
  if (index >= 0 && !(access != O_RDONLY && (flags & O_TRUNC))) {
    data = save_load(index, &length);
    if (data == NULL) {
      save_unreadable |= 1u << save_state->files[index].head;
      xSemaphoreGive(save_lock);
      save_log("could not read %s; it will not be written over this boot",
               name);
      errno = EIO;
      return -1;
    }
  }
  memset(&save_files[fd], 0, sizeof(save_files[fd]));
  save_files[fd].open = true;
  save_files[fd].writable = access != O_RDONLY;
  save_files[fd].append = (flags & O_APPEND) != 0;
  // A truncated file is new content even when empty.
  save_files[fd].dirty = save_files[fd].writable && data == NULL;
  strncpy(save_files[fd].name, name, SAVE_STORE_NAME_BYTES - 1);
  save_files[fd].data = data;
  save_files[fd].length = length;
  save_files[fd].capacity = length;
  xSemaphoreGive(save_lock);
  return fd;
}

ssize_t save_file_read(int fd, void* dst, size_t size) {
  if (!save_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  const uint32_t position = save_files[fd].position;
  const uint32_t length = save_files[fd].length;
  const size_t n = position >= length ? 0
                   : size < length - position ? size
                                              : length - position;
  if (n > 0) memcpy(dst, save_files[fd].data + position, n);
  save_files[fd].position += (uint32_t)n;
  return (ssize_t)n;
}

ssize_t save_file_write(int fd, const void* src, size_t size) {
  if (!save_fd_valid(fd) || !save_files[fd].writable) {
    errno = EBADF;
    return -1;
  }
  if (save_files[fd].append) save_files[fd].position = save_files[fd].length;
  const uint32_t position = save_files[fd].position;
  if (size > SAVE_FILE_MAX_BYTES || position > SAVE_FILE_MAX_BYTES - size) {
    save_files[fd].failed = true;
    errno = EFBIG;
    return -1;
  }
  const uint32_t end = position + (uint32_t)size;
  if (end > save_files[fd].capacity) {
    uint32_t capacity = save_files[fd].capacity < 4096
                            ? 4096
                            : save_files[fd].capacity;
    while (capacity < end) capacity *= 2;
    uint8_t* grown = (uint8_t*)heap_caps_realloc(
        save_files[fd].data, capacity, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (grown == NULL) {
      save_files[fd].failed = true;
      errno = ENOMEM;
      return -1;
    }
    save_files[fd].data = grown;
    save_files[fd].capacity = capacity;
  }
  if (position > save_files[fd].length) {
    memset(save_files[fd].data + save_files[fd].length, 0,
           position - save_files[fd].length);
  }
  memcpy(save_files[fd].data + position, src, size);
  save_files[fd].position = end;
  if (end > save_files[fd].length) save_files[fd].length = end;
  save_files[fd].dirty = true;
  return (ssize_t)size;
}

off_t save_file_lseek(int fd, off_t offset, int whence) {
  if (!save_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  int64_t base = 0;
  if (whence == SEEK_CUR) base = save_files[fd].position;
  else if (whence == SEEK_END) base = save_files[fd].length;
  else if (whence != SEEK_SET) base = -1;
  const int64_t target = base < 0 ? -1 : base + (int64_t)offset;
  if (target < 0 || target > SAVE_FILE_MAX_BYTES) {
    errno = EINVAL;
    return -1;
  }
  save_files[fd].position = (uint32_t)target;
  return (off_t)target;
}

// Stores a closed file's bytes; NULL, or why it was not stored.
static const char* save_commit(const char* name, const uint8_t* data,
                               uint32_t length) {
  const uint32_t crc = save_store_crc32(0, data, length);
  if (save_store_unchanged(save_state, name, length, crc)) return NULL;
  const int old = save_store_find(save_state, name);
  if (old >= 0 && (save_unreadable & (1u << save_state->files[old].head))) {
    save_log("not writing %s: its stored copy could not be read", name);
    return "stored copy unreadable";
  }
  uint32_t stored = length;
  uint8_t* packed = save_deflate(data, length, &stored);
  const char* failure = save_store_write(
      save_state, name, packed != NULL ? packed : data, stored, length, crc,
      packed != NULL ? SAVE_STORE_ENCODING_DEFLATE : SAVE_STORE_ENCODING_RAW);
  free(packed);
  if (failure == NULL) {
    save_log("wrote %s: %u bytes (%u stored), %u of %u sectors free", name,
             (unsigned)length, (unsigned)stored,
             (unsigned)save_store_free_sectors(save_state),
             (unsigned)save_state->sectors);
  } else {
    save_log("could not write %s (%u bytes, %u stored): %s", name,
             (unsigned)length, (unsigned)stored, failure);
  }
  return failure;
}

int save_file_close(int fd) {
  if (!save_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  xSemaphoreTake(save_lock, portMAX_DELAY);
  const char* failure = NULL;
  if (save_files[fd].failed) {
    // Part of the file never arrived; storing the rest would replace a good
    // copy with a damaged one.
    save_log("not writing %s: a write to it failed", save_files[fd].name);
    failure = "write failed";
  } else if (save_files[fd].dirty) {
    static const uint8_t empty = 0;
    failure = save_commit(save_files[fd].name,
                          save_files[fd].data != NULL ? save_files[fd].data
                                                      : &empty,
                          save_files[fd].length);
  }
  free(save_files[fd].data);
  memset(&save_files[fd], 0, sizeof(save_files[fd]));
  xSemaphoreGive(save_lock);
  if (failure != NULL) {
    errno = ENOSPC;
    return -1;
  }
  return 0;
}

int save_file_fstat(int fd, struct stat* st) {
  if (!save_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  memset(st, 0, sizeof(*st));
  st->st_mode = S_IFREG | 0666;
  st->st_size = save_files[fd].length;
  return 0;
}

int save_file_stat(const char* name, struct stat* st) {
  if (!save_store_ready()) {
    errno = ENODEV;
    return -1;
  }
  xSemaphoreTake(save_lock, portMAX_DELAY);
  const int index = save_store_find(save_state, name);
  const uint32_t bytes = index >= 0 ? save_state->files[index].raw_bytes : 0;
  xSemaphoreGive(save_lock);
  if (index < 0) {
    errno = ENOENT;
    return -1;
  }
  memset(st, 0, sizeof(*st));
  st->st_mode = S_IFREG | 0666;
  st->st_size = bytes;
  return 0;
}

int save_file_unlink(const char* name) {
  if (!save_store_ready()) {
    errno = ENODEV;
    return -1;
  }
  xSemaphoreTake(save_lock, portMAX_DELAY);
  const int index = save_store_find(save_state, name);
  const bool exists = index >= 0;
  if (exists) save_unreadable &= ~(1u << save_state->files[index].head);
  const bool removed = exists && save_store_remove(save_state, name);
  xSemaphoreGive(save_lock);
  if (!removed) {
    errno = exists ? EIO : ENOENT;
    return -1;
  }
  save_log("removed %s", name);
  return 0;
}

// ---- /save ------------------------------------------------------------------

static int save_vfs_open(const char* path, int flags, int mode) {
  (void)mode;
  char name[SAVE_STORE_NAME_BYTES];
  if (!save_store_name_from_path(NULL, path, name)) {
    errno = ENOENT;
    return -1;
  }
  return save_file_open(name, flags);
}

static int save_vfs_stat(const char* path, struct stat* st) {
  char name[SAVE_STORE_NAME_BYTES];
  if (!save_store_name_from_path(NULL, path, name)) {
    errno = ENOENT;
    return -1;
  }
  return save_file_stat(name, st);
}

static int save_vfs_unlink(const char* path) {
  char name[SAVE_STORE_NAME_BYTES];
  if (!save_store_name_from_path(NULL, path, name)) {
    errno = ENOENT;
    return -1;
  }
  return save_file_unlink(name);
}

static const esp_vfs_t save_vfs = {
    .flags = ESP_VFS_FLAG_DEFAULT,
    .write = &save_file_write,
    .lseek = &save_file_lseek,
    .read = &save_file_read,
    .open = &save_vfs_open,
    .close = &save_file_close,
    .fstat = &save_file_fstat,
    .stat = &save_vfs_stat,
    .unlink = &save_vfs_unlink,
};

const char* save_store_open(void) {
  if (save_tried) return save_failure;
  save_tried = true;
  save_failure = save_register_area();
  if (save_failure != NULL) return save_failure;
  save_lock = xSemaphoreCreateMutex();
  save_state = (save_store_t*)save_alloc(sizeof(*save_state));
  if (save_lock == NULL || save_state == NULL) {
    save_failure = "no memory for the save store";
    return save_failure;
  }
  const save_store_flash_t flash = {NULL, save_area_read, save_area_write,
                                    save_area_erase};
  save_failure = save_store_mount(save_state, flash,
                                  SAVE_AREA_BYTES / SAVE_STORE_SECTOR_BYTES);
  if (save_failure != NULL) return save_failure;
  if (esp_vfs_register(SAVE_STORE_MOUNT, &save_vfs, NULL) != ESP_OK) {
    save_failure = "could not register the /save file system";
    return save_failure;
  }
  save_log("store at 0x%06x: %d file(s), %u of %u sectors free",
           (unsigned)save_area->address, save_state->count,
           (unsigned)save_store_free_sectors(save_state),
           (unsigned)save_state->sectors);
  for (int i = 0; i < save_state->count; ++i) {
    save_log("  %s: %u bytes (%u stored)", save_state->files[i].name,
             (unsigned)save_state->files[i].raw_bytes,
             (unsigned)save_state->files[i].stored_bytes);
  }
  return NULL;
}
