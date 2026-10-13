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
// Files are compressed with the ROM's deflate (miniz) as they are written,
// and inflated as they are read: Quake's text saves shrink several times
// over, which is what makes room for them, and no whole raw file is ever
// held in memory.
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

// ---- Memory -----------------------------------------------------------------

// A file in the store is at most the area less one header. Deflate's state
// (about 160 KB) and that much output are what a write needs at most; a
// read needs inflate's state and its 32 KB window. Neither ever holds a
// whole raw file, which on an S3 running Quake would not fit: its engine
// heap leaves about 120 KB of PSRAM.
#define SAVE_OUT_BYTES (SAVE_AREA_BYTES - SAVE_STORE_HEAD_BYTES)
// A file this small is kept whole until it is closed, so an unchanged
// config is recognised by its CRC without deflating anything.
#define SAVE_SMALL_BYTES 8192u
#define SAVE_IN_CHUNK 1024u

typedef struct {
  tdefl_compressor deflate;
  uint8_t out[SAVE_OUT_BYTES];
} save_packer_t;

typedef struct {
  tinfl_decompressor inflate;
  uint8_t window[TINFL_LZ_DICT_SIZE];
  uint8_t in[SAVE_IN_CHUNK];
} save_unpacker_t;

// PSRAM only: a game boot has it, and internal RAM is the panel's and the
// flash driver's.
static void* save_alloc(size_t bytes) {
  return heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
}

// Where a write's deflate state comes from when the heap has too little: the
// Quake boot lends the top of its engine heap (save_store_set_arena).
static void* (*save_arena_take)(size_t bytes) = NULL;
static void (*save_arena_give)(void) = NULL;

void save_store_set_arena(void* (*take)(size_t bytes), void (*give)(void)) {
  save_arena_take = take;
  save_arena_give = give;
}

// ---- Files ------------------------------------------------------------------

typedef struct {
  bool open;
  bool writable;
  bool failed;   // a write failed or did not fit: nothing is stored on close
  bool too_big;  // ...because the file does not fit the area
  char name[SAVE_STORE_NAME_BYTES];
  uint32_t crc;  // of the raw bytes written, or read so far
  // Reading: the record as opened, and where the stream is.
  uint32_t sequence;
  uint8_t encoding;
  uint32_t raw_bytes;
  uint32_t raw_crc_expected;
  uint32_t stored_bytes;
  uint32_t position;  // where the next read() starts
  uint32_t produced;  // raw bytes the stream has given out
  uint32_t consumed;  // stored bytes fed to inflate
  save_unpacker_t* unpacker;
  uint32_t window_at;  // where inflate writes next in the window
  uint32_t pending_at, pending;  // output not yet given out
  uint32_t in_at, in_left;
  bool done;
  // Writing.
  uint32_t length;  // raw bytes written
  uint8_t* small;   // the first SAVE_SMALL_BYTES, while that is all there is
  save_packer_t* packer;
  bool packer_borrowed;
  uint32_t out_length;
} save_file_t;

static save_file_t save_files[SAVE_FILE_MAX_OPEN];

static bool save_fd_valid(int fd) {
  return fd >= 0 && fd < SAVE_FILE_MAX_OPEN && save_files[fd].open;
}

bool save_store_ready(void) { return save_tried && save_failure == NULL; }

// Stored bytes of the record the file was opened on; false when the flash
// read failed or the record has since been replaced. save_lock held.
static bool save_read_stored(const save_file_t* f, uint32_t at, void* out,
                             uint32_t length) {
  const int index = save_store_find(save_state, f->name);
  return index >= 0 && save_state->files[index].sequence == f->sequence &&
         save_store_read(save_state, index, at, out, length);
}

static void save_stream_reset(save_file_t* f) {
  if (f->unpacker != NULL) tinfl_init(&f->unpacker->inflate);
  f->produced = f->consumed = 0;
  f->window_at = f->pending_at = f->pending = 0;
  f->in_at = f->in_left = 0;
  f->done = false;
  f->crc = 0;
}

// Gives out up to `want` raw bytes from the stream into `dst` (or drops them
// when dst is NULL). 1 with *got set, 0 when the stored bytes are damaged,
// -1 when the flash could not be read. save_lock held.
static int save_stream_next(save_file_t* f, uint8_t* dst, uint32_t want,
                            uint32_t* got) {
  *got = 0;
  if (f->encoding == SAVE_STORE_ENCODING_RAW) {
    uint32_t n = f->raw_bytes - f->produced;
    if (n > want) n = want;
    while (*got < n) {
      uint8_t chunk[256];
      uint32_t step = n - *got;
      if (step > sizeof(chunk)) step = sizeof(chunk);
      uint8_t* to = dst != NULL ? dst + *got : chunk;
      if (!save_read_stored(f, f->produced, to, step)) return -1;
      f->crc = save_store_crc32(f->crc, to, step);
      f->produced += step;
      *got += step;
    }
    return 1;
  }
  save_unpacker_t* u = f->unpacker;
  while (*got < want) {
    if (f->pending > 0) {
      uint32_t n = want - *got;
      if (n > f->pending) n = f->pending;
      const uint8_t* from = u->window + f->pending_at;
      if (dst != NULL) memcpy(dst + *got, from, n);
      f->crc = save_store_crc32(f->crc, from, n);
      f->pending_at += n;
      f->pending -= n;
      f->produced += n;
      *got += n;
      if (f->produced > f->raw_bytes) return 0;
      continue;
    }
    if (f->done) break;
    if (f->in_left == 0 && f->consumed < f->stored_bytes) {
      uint32_t n = f->stored_bytes - f->consumed;
      if (n > SAVE_IN_CHUNK) n = SAVE_IN_CHUNK;
      if (!save_read_stored(f, f->consumed, u->in, n)) return -1;
      f->in_at = 0;
      f->in_left = n;
      f->consumed += n;
    }
    size_t in_size = f->in_left;
    size_t out_size = TINFL_LZ_DICT_SIZE - f->window_at;
    const int flags = f->consumed < f->stored_bytes ? TINFL_FLAG_HAS_MORE_INPUT : 0;
    const tinfl_status status =
        tinfl_decompress(&u->inflate, u->in + f->in_at, &in_size, u->window,
                         u->window + f->window_at, &out_size, flags);
    f->in_at += (uint32_t)in_size;
    f->in_left -= (uint32_t)in_size;
    f->pending_at = f->window_at;
    f->pending = (uint32_t)out_size;
    f->window_at = (f->window_at + (uint32_t)out_size) & (TINFL_LZ_DICT_SIZE - 1);
    if (status == TINFL_STATUS_DONE) {
      f->done = true;
    } else if (status < 0) {
      return 0;
    } else if (status == TINFL_STATUS_NEEDS_MORE_INPUT && f->in_left == 0 &&
               f->consumed >= f->stored_bytes && out_size == 0) {
      return 0;  // the stream stops short
    }
  }
  return 1;
}

// Reads the whole file once, checking its length and CRC, then rewinds.
// 1 whole, 0 damaged, -1 the flash could not be read. save_lock held.
static int save_stream_verify(save_file_t* f) {
  save_stream_reset(f);
  for (;;) {
    uint32_t got = 0;
    const int r = save_stream_next(f, NULL, 4096, &got);
    if (r <= 0) return r;
    if (got == 0) break;
  }
  const bool whole = f->produced == f->raw_bytes && f->crc == f->raw_crc_expected;
  save_stream_reset(f);
  return whole ? 1 : 0;
}

static void save_packer_release(save_file_t* f) {
  if (f->packer != NULL) {
    if (f->packer_borrowed) {
      if (save_arena_give != NULL) save_arena_give();
    } else {
      free(f->packer);
    }
  }
  f->packer = NULL;
  f->packer_borrowed = false;
}

static void save_release(save_file_t* f) {
  free(f->unpacker);
  free(f->small);
  save_packer_release(f);
  memset(f, 0, sizeof(*f));
}

int save_file_open(const char* name, int flags) {
  if (!save_store_ready()) {
    errno = ENODEV;
    return -1;
  }
  if (!save_store_name_valid(name)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  const int access = flags & O_ACCMODE;
  // Writes stream to flash through deflate, so a file is only ever written
  // whole, from the start: "w", never "a" or "r+".
  if (access != O_RDONLY && !(flags & O_TRUNC)) {
    errno = EINVAL;
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
  save_file_t* f = &save_files[fd];
  memset(f, 0, sizeof(*f));
  strncpy(f->name, name, SAVE_STORE_NAME_BYTES - 1);
  if (access != O_RDONLY) {
    if (!(flags & O_CREAT) && save_store_find(save_state, name) < 0) {
      xSemaphoreGive(save_lock);
      errno = ENOENT;
      return -1;
    }
    f->open = true;
    f->writable = true;
    xSemaphoreGive(save_lock);
    return fd;
  }
  const int index = save_store_find(save_state, name);
  if (index < 0) {
    xSemaphoreGive(save_lock);
    errno = ENOENT;
    return -1;
  }
  const save_store_file_t* record = &save_state->files[index];
  f->sequence = record->sequence;
  f->encoding = record->encoding;
  f->raw_bytes = record->raw_bytes;
  f->raw_crc_expected = record->raw_crc;
  f->stored_bytes = record->stored_bytes;
  int whole = -1;  // no memory counts as a passing failure
  if (f->encoding == SAVE_STORE_ENCODING_RAW ||
      (f->unpacker = (save_unpacker_t*)save_alloc(sizeof(save_unpacker_t))) !=
          NULL) {
    whole = save_stream_verify(f);
  }
  if (whole <= 0) {
    // A damaged copy may be written over; one that only could not be read
    // just now is kept, since the game will fall back to its defaults.
    if (whole < 0) save_unreadable |= 1u << record->head;
    save_release(f);
    xSemaphoreGive(save_lock);
    save_log(whole < 0 ? "could not read %s; not writing over it this boot"
                       : "%s is damaged; it will be replaced when written",
             name);
    errno = EIO;
    return -1;
  }
  f->open = true;
  xSemaphoreGive(save_lock);
  return fd;
}

ssize_t save_file_read(int fd, void* dst, size_t size) {
  if (!save_fd_valid(fd) || save_files[fd].writable) {
    errno = EBADF;
    return -1;
  }
  save_file_t* f = &save_files[fd];
  xSemaphoreTake(save_lock, portMAX_DELAY);
  // A seek back starts the stream again; a seek on skips forward.
  if (f->position < f->produced) save_stream_reset(f);
  int result = 1;
  while (result > 0 && f->produced < f->position) {
    uint32_t skip = f->position - f->produced, got = 0;
    if (skip > 4096) skip = 4096;
    result = save_stream_next(f, NULL, skip, &got);
    if (result > 0 && got == 0) break;
  }
  uint32_t got = 0;
  if (result > 0 && f->position < f->raw_bytes) {
    uint32_t want = f->raw_bytes - f->position;
    if (want > size) want = (uint32_t)size;
    result = save_stream_next(f, (uint8_t*)dst, want, &got);
    f->position += got;
  }
  xSemaphoreGive(save_lock);
  if (result <= 0) {
    errno = EIO;
    return -1;
  }
  return (ssize_t)got;
}

// Feeds deflate; FINISH as `flush` ends the stream. False when it fails or
// the output outgrows the area.
static bool save_pack(save_file_t* f, const uint8_t* in, uint32_t length,
                      tdefl_flush flush) {
  save_packer_t* p = f->packer;
  for (;;) {
    size_t in_size = length;
    size_t out_size = SAVE_OUT_BYTES - f->out_length;
    const tdefl_status status = tdefl_compress(
        &p->deflate, in, &in_size, p->out + f->out_length, &out_size, flush);
    f->out_length += (uint32_t)out_size;
    in += in_size;
    length -= (uint32_t)in_size;
    if (status < 0) return false;
    if (flush == TDEFL_FINISH ? status == TDEFL_STATUS_DONE : length == 0) {
      return true;
    }
    if (f->out_length >= SAVE_OUT_BYTES || (in_size == 0 && out_size == 0)) {
      f->too_big = f->out_length >= SAVE_OUT_BYTES;
      return false;
    }
  }
}

// Starts deflate, from the heap or else (when `borrow`) the arena.
static bool save_packer_start(save_file_t* f, bool borrow) {
  f->packer = (save_packer_t*)save_alloc(sizeof(save_packer_t));
  f->packer_borrowed = false;
  if (f->packer == NULL && borrow && save_arena_take != NULL) {
    f->packer = (save_packer_t*)save_arena_take(sizeof(save_packer_t));
    f->packer_borrowed = f->packer != NULL;
  }
  if (f->packer == NULL) return false;
  f->out_length = 0;
  return tdefl_init(&f->packer->deflate, NULL, NULL,
                    TDEFL_DEFAULT_MAX_PROBES) == TDEFL_STATUS_OKAY;
}

ssize_t save_file_write(int fd, const void* src, size_t size) {
  if (!save_fd_valid(fd) || !save_files[fd].writable) {
    errno = EBADF;
    return -1;
  }
  save_file_t* f = &save_files[fd];
  // After a failure the rest is taken and dropped: close says what happened.
  if (f->failed || size == 0) return (ssize_t)size;
  if (size > SAVE_FILE_MAX_BYTES || f->length > SAVE_FILE_MAX_BYTES - size) {
    f->failed = f->too_big = true;
    return (ssize_t)size;
  }
  f->crc = save_store_crc32(f->crc, (const uint8_t*)src, size);
  if (f->packer == NULL && f->length + size <= SAVE_SMALL_BYTES) {
    if (f->small == NULL) f->small = (uint8_t*)save_alloc(SAVE_SMALL_BYTES);
    if (f->small == NULL) {
      f->failed = true;
      return (ssize_t)size;
    }
    memcpy(f->small + f->length, src, size);
    f->length += (uint32_t)size;
    return (ssize_t)size;
  }
  if (f->packer == NULL) {
    if (!save_packer_start(f, true) ||
        (f->length > 0 &&
         !save_pack(f, f->small, f->length, TDEFL_NO_FLUSH))) {
      f->failed = true;
      return (ssize_t)size;
    }
    free(f->small);
    f->small = NULL;
  }
  if (!save_pack(f, (const uint8_t*)src, (uint32_t)size, TDEFL_NO_FLUSH)) {
    // Give the deflate state (perhaps borrowed) back now, not at close.
    f->failed = true;
    save_packer_release(f);
  }
  f->length += (uint32_t)size;
  return (ssize_t)size;
}

off_t save_file_lseek(int fd, off_t offset, int whence) {
  if (!save_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  save_file_t* f = &save_files[fd];
  const int64_t end = f->writable ? f->length : f->raw_bytes;
  int64_t base = -1;
  if (whence == SEEK_SET) base = 0;
  else if (whence == SEEK_CUR) base = f->writable ? f->length : f->position;
  else if (whence == SEEK_END) base = end;
  const int64_t target = base < 0 ? -1 : base + (int64_t)offset;
  // A write stream only goes forward from where it is (ftell works).
  if (target < 0 || target > end || (f->writable && target != end)) {
    errno = EINVAL;
    return -1;
  }
  if (!f->writable) f->position = (uint32_t)target;
  return (off_t)target;
}

int save_file_close(int fd) {
  if (!save_fd_valid(fd)) {
    errno = EBADF;
    return -1;
  }
  save_file_t* f = &save_files[fd];
  xSemaphoreTake(save_lock, portMAX_DELAY);
  const char* failure = NULL;
  if (f->writable) {
    static const uint8_t empty = 0;
    const uint8_t* payload = NULL;
    uint32_t stored = 0;
    int encoding = SAVE_STORE_ENCODING_DEFLATE;
    if (f->failed) {
      failure = f->too_big ? SAVE_STORE_FULL : "a write to it failed";
    } else if (save_store_unchanged(save_state, f->name, f->length, f->crc)) {
      // Nothing to do; the flash keeps what it has.
    } else if (f->packer == NULL) {
      // Small: deflate it now, or keep it raw when that is no smaller. Never
      // with borrowed memory: a config fits raw, and a loan would make Quake
      // evict and reload cached data.
      if (f->length >= 64 && save_packer_start(f, false) &&
          save_pack(f, f->small, f->length, TDEFL_FINISH) &&
          f->out_length < f->length) {
        payload = f->packer->out;
        stored = f->out_length;
      } else {
        payload = f->small != NULL ? f->small : &empty;
        stored = f->length;
        encoding = SAVE_STORE_ENCODING_RAW;
      }
    } else if (save_pack(f, NULL, 0, TDEFL_FINISH)) {
      payload = f->packer->out;
      stored = f->out_length;
    } else {
      failure = f->too_big ? SAVE_STORE_FULL : "deflate failed";
    }
    if (failure == NULL && payload != NULL) {
      const int old = save_store_find(save_state, f->name);
      if (old >= 0 &&
          (save_unreadable & (1u << save_state->files[old].head))) {
        failure = "its stored copy could not be read";
      } else {
        failure = save_store_write(save_state, f->name, payload, stored,
                                   f->length, f->crc, encoding);
      }
      if (failure == NULL) {
        save_log("wrote %s: %u bytes (%u stored), %u of %u sectors free",
                 f->name, (unsigned)f->length, (unsigned)stored,
                 (unsigned)save_store_free_sectors(save_state),
                 (unsigned)save_state->sectors);
      }
    }
    if (failure != NULL) {
      save_log("could not write %s (%u bytes): %s", f->name,
               (unsigned)f->length, failure);
    }
  }
  save_release(f);
  xSemaphoreGive(save_lock);
  if (failure != NULL) {
    errno = failure == SAVE_STORE_FULL ? ENOSPC : EIO;
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
  st->st_size =
      save_files[fd].writable ? save_files[fd].length : save_files[fd].raw_bytes;
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
