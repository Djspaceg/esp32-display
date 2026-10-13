// The saved-games store (platform/save_store_model.h has the format): game
// configs and saves kept across restarts in the 60 KB beside doom_wad.
// C linkage: the Doom boot mounts it at /save, and the Quake boot serves
// everything in /qdata that is not a pak from it.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "platform/save_store_model.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SAVE_STORE_MOUNT "/save"

// Finds the area, reads it and registers /save, once a boot. NULL when the
// store is usable, else a short reason for the serial log (games then run
// with nothing kept, as before). Call from a task with an internal stack.
const char* save_store_open(void);

// Whether save_store_open() succeeded.
bool save_store_ready(void);

// Memory a write may borrow when the heap cannot give its deflate state
// (about 220 KB): `take` lends that many bytes or NULL, `give` takes them
// back. At most one loan at a time (a second large write meanwhile fails),
// from a write past 8 KB to its close or failure, on the task that writes,
// and never for a file of 8 KB or less. The Quake boot lends the top of its
// engine heap.
void save_store_set_arena(void* (*take)(size_t bytes), void (*give)(void));

// Files by store name ("quake/id1/config.cfg"), for a VFS that forwards to
// the store. As POSIX: -1 with errno on failure. A file is written whole from
// the start ("w"; never "a" or "r+"), deflated as it is written, and goes to
// flash when it is closed; close fails
// with ENOSPC when there was no room (the old copy, if any, stays) and EIO
// when a write to it or the flash failed. Any task, PSRAM stacks included.
int save_file_open(const char* name, int flags);
ssize_t save_file_read(int fd, void* dst, size_t size);
ssize_t save_file_write(int fd, const void* src, size_t size);
off_t save_file_lseek(int fd, off_t offset, int whence);
int save_file_close(int fd);
int save_file_fstat(int fd, struct stat* st);
int save_file_stat(const char* name, struct stat* st);
int save_file_unlink(const char* name);

#ifdef __cplusplus
}
#endif
