/* Test/development-only clean rollback-fixture VFS. Never canonical admission. */
#include "swarm_guard.h"
#include <stdatomic.h>
typedef struct GuardVfs {
  sqlite3_vfs vfs; /* first: pAppData must remain the SQLite IO finder */
  int admitted;
  struct stat identity;
  int opened;
  int sidecar_attempts;
  int active;
  sqlite3_io_methods methods;
  char *path;
  char name[64];
  int registered;
} GuardVfs;

typedef struct GuardFile {
  unixFile file;
  GuardVfs *guard;
} GuardFile;

static _Atomic int guard_registrations;

static int guard_file_close(sqlite3_file *file) {
  GuardVfs *g = ((GuardFile *)file)->guard;
  int rc = unixClose(file);
  if (rc == SQLITE_OK) g->active = 0;
  return rc;
}

static int guard_shm_map(sqlite3_file *file, int page, int size, int extend, void volatile **out) {
  (void)file; (void)page; (void)size; (void)extend; (void)out;
  return SQLITE_IOERR_SHMMAP;
}

static int guard_file_control(sqlite3_file *file, int op, void *arg) {
  if (op == SQLITE_FCNTL_VFS_POINTER || op == SQLITE_FCNTL_VFSNAME ||
      op == SQLITE_FCNTL_TEMPFILENAME) return SQLITE_NOTFOUND;
  return unixFileControl(file, op, arg);
}

static int same_identity(const struct stat *a, const struct stat *b) {
  return S_ISREG(a->st_mode) && S_ISREG(b->st_mode) &&
    a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
    a->st_uid == b->st_uid;
}

static int guard_open(sqlite3_vfs *vfs, const char *path,
                      sqlite3_file *file, int flags, int *out_flags) {
  GuardVfs *guard = (GuardVfs *)vfs;
  unixFile *p = (unixFile *)file;
  int fd, rc, ctrl = 0;
  struct stat identity;
#if defined(__APPLE__) || SQLITE_ENABLE_LOCKING_STYLE
  struct statfs fs;
#endif
  memset(file, 0, sizeof(GuardFile));
  p->h = -1;
  if ((flags & 0x0FFF00) != SQLITE_OPEN_MAIN_DB) {
    guard->sidecar_attempts++;
    return SQLITE_CANTOPEN;
  }
  /* Narrow proof: existing local DB, no URI/proxy/create/delete semantics. */
  if (!path || guard->opened ||
      (flags & (SQLITE_OPEN_CREATE | SQLITE_OPEN_DELETEONCLOSE |
                SQLITE_OPEN_EXCLUSIVE | SQLITE_OPEN_URI |
                SQLITE_OPEN_AUTOPROXY)) ||
      !(flags & SQLITE_OPEN_READONLY) || (flags & SQLITE_OPEN_READWRITE)) {
    return SQLITE_CANTOPEN;
  }
  if (randomnessPid != osGetpid(0)) {
    randomnessPid = osGetpid(0);
    sqlite3_randomness(0, 0);
  }
  /* Do not use findReusableFd(path): the path names the OTHER fixture. */
  p->pPreallocatedUnused = sqlite3_malloc64(sizeof(UnixUnusedFd));
  if (!p->pPreallocatedUnused) return SQLITE_NOMEM;
  memset(p->pPreallocatedUnused, 0, sizeof(UnixUnusedFd));
  /* F_DUPFD_CLOEXEC is the atomic close-on-exec equivalent of dup(). */
  fd = fcntl(guard->admitted, F_DUPFD_CLOEXEC, 3);
  if (fd < 0) {
    sqlite3_free(p->pPreallocatedUnused);
    p->pPreallocatedUnused = 0;
    return SQLITE_CANTOPEN;
  }
  if (fstat(fd, &identity) != 0 || !same_identity(&identity, &guard->identity)) {
    rc = SQLITE_CANTOPEN;
    goto before_fill_failure;
  }
  p->pPreallocatedUnused->fd = fd;
  p->pPreallocatedUnused->flags =
    flags & (SQLITE_OPEN_READONLY | SQLITE_OPEN_READWRITE);
#if SQLITE_ENABLE_LOCKING_STYLE
  p->openFlags = ((flags & SQLITE_OPEN_READONLY) ? O_RDONLY : O_RDWR) |
    O_LARGEFILE | O_BINARY | O_NOFOLLOW;
#endif
#if defined(__APPLE__) || SQLITE_ENABLE_LOCKING_STYLE
  if (fstatfs(fd, &fs) == -1) {
    storeLastErrno(p, errno);
    rc = SQLITE_IOERR_ACCESS;
    goto before_fill_failure;
  }
  if (!strncmp("msdos", fs.f_fstypename, 5) ||
      !strncmp("exfat", fs.f_fstypename, 5)) {
    p->fsFlags |= SQLITE_FSFLAGS_IS_MSDOS;
  }
#endif
  if (flags & SQLITE_OPEN_READONLY) ctrl |= UNIXFILE_RDONLY;
  /* Retains real POSIX locks, inode registration, mmap setup and unixClose. */
  rc = fillInUnixFile(vfs, fd, file, path, ctrl);
  if (rc != SQLITE_OK) {
    /* fillInUnixFile already closed fd on failure. Never double-close. */
    sqlite3_free(p->pPreallocatedUnused);
    p->pPreallocatedUnused = 0;
    p->h = -1;
    return rc;
  }
  if (out_flags) *out_flags = flags;
  guard->opened++;
  guard->active = 1;
  ((GuardFile *)file)->guard = guard;
  p->pMethod = &guard->methods;
  return SQLITE_OK;

before_fill_failure:
  robust_close(p, fd, __LINE__);
  sqlite3_free(p->pPreallocatedUnused);
  p->pPreallocatedUnused = 0;
  return rc;
}

static int guard_access(sqlite3_vfs *vfs, const char *path, int flags, int *out) {
  /* Fixtures are clean rollback DBs. No sidecar existence lookup is needed. */
  (void)vfs; (void)path; (void)flags;
  *out = 0;
  return SQLITE_OK;
}

static int guard_delete(sqlite3_vfs *vfs, const char *path, int sync) {
  (void)vfs; (void)path; (void)sync;
  return SQLITE_IOERR_DELETE;
}

int swarm_guard_admit(const char *path, GuardVfs **out) {
  unsigned char random[16];
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  struct stat identity;
  if (fd < 0) return SQLITE_CANTOPEN;
  if (fstat(fd, &identity) != 0 || !S_ISREG(identity.st_mode) ||
      identity.st_uid != getuid() || (identity.st_mode & 07777) != 0600) {
    close(fd);
    return SQLITE_CANTOPEN;
  }
  unsigned char header[100];
  if (pread(fd, header, sizeof(header), 0) != sizeof(header) ||
      memcmp(header, "SQLite format 3\0", 16) || header[18] != 1 || header[19] != 1) {
    close(fd);
    return SQLITE_CANTOPEN;
  }
  const char *suffixes[] = {"-journal", "-wal", "-shm"};
  for (unsigned i = 0; i < 3; i++) {
    char *sidecar = sqlite3_mprintf("%s%s", path, suffixes[i]);
    struct stat side;
    if (!sidecar) { close(fd); return SQLITE_NOMEM; }
    int present = lstat(sidecar, &side);
    int absent = present == -1 && errno == ENOENT;
    sqlite3_free(sidecar);
    if (!absent) { close(fd); return SQLITE_CANTOPEN; }
  }
  GuardVfs *g = sqlite3_malloc64(sizeof(*g));
  if (!g) { close(fd); return SQLITE_NOMEM; }
  memset(g, 0, sizeof(*g));
  g->admitted = fd;
  g->identity = identity;

  g->path = sqlite3_mprintf("%s", path);
  if (!g->path) { close(fd); sqlite3_free(g); return SQLITE_NOMEM; }
  g->vfs = *sqlite3_vfs_find("unix");
  g->vfs.pNext = 0;
  g->vfs.szOsFile = sizeof(GuardFile);
  g->methods = posixIoMethods;
  g->methods.xClose = guard_file_close;
  g->methods.xShmMap = guard_shm_map;
  g->methods.xFileControl = guard_file_control;
  g->vfs.pAppData = (void *)&posixIoFinder;
  g->vfs.xOpen = guard_open;
  g->vfs.xAccess = guard_access;
  g->vfs.xDelete = guard_delete;
  sqlite3_randomness(sizeof(random), random);
  g->name[0] = 'g';
  for (unsigned i = 0; i < sizeof(random); i++) {
    sqlite3_snprintf(3, g->name + 1 + 2*i, "%02x", random[i]);
  }
  g->vfs.zName = g->name;
  *out = g;
  return SQLITE_OK;
}

int swarm_guard_open(GuardVfs *g, sqlite3 **out) {
  if (g->opened || g->active) return SQLITE_MISUSE;
  int rc = sqlite3_vfs_register(&g->vfs, 0);
  if (rc != SQLITE_OK) return rc;
  g->registered = 1;
  atomic_fetch_add(&guard_registrations, 1);
  rc = sqlite3_open_v2(g->path, out, SQLITE_OPEN_READONLY, g->vfs.zName);
  sqlite3_vfs_unregister(&g->vfs);
  g->registered = 0;
  atomic_fetch_sub(&guard_registrations, 1);
  if (rc != SQLITE_OK) {
    sqlite3_close_v2(*out);
    *out = 0;
    return rc;
  }
  return SQLITE_OK;
}

int swarm_guard_identity(GuardVfs *g, struct stat *identity) {
  if (fstat(g->admitted, identity) != 0) return SQLITE_IOERR;
  return same_identity(identity, &g->identity) ? SQLITE_OK : SQLITE_IOERR;
}

int swarm_guard_connection_identity(sqlite3 *db, struct stat *identity) {
  sqlite3_file *file = 0;
  int rc = sqlite3_file_control(db, "main", SQLITE_FCNTL_FILE_POINTER, &file);
  if (rc != SQLITE_OK || !file) return SQLITE_IOERR;
  unixFile *p = (unixFile *)file;
  GuardVfs *g = ((GuardFile *)file)->guard;
  if (!g || p->pMethod != &g->methods || !p->pInode || !p->pPreallocatedUnused ||
      p->pPreallocatedUnused->fd != p->h ||
      !(fcntl(p->h, F_GETFD) & FD_CLOEXEC)) return SQLITE_IOERR;
  return fstat(p->h, identity) == 0 ? SQLITE_OK : SQLITE_IOERR;
}

int swarm_guard_connection_done(GuardVfs *g) {
  return g->active ? SQLITE_BUSY : SQLITE_OK;
}

int swarm_guard_registration_count(void) {
  return atomic_load(&guard_registrations);
}

int swarm_guard_dispose(GuardVfs *g) {
  if (g->active) return SQLITE_BUSY;
  if (g->registered) return SQLITE_BUSY;
  int fd = g->admitted;
  int rc = close(fd);
  sqlite3_free(g->path);
  sqlite3_free(g);
  return rc == 0 ? SQLITE_OK : SQLITE_IOERR;
}
