/* Production single-connection lease VFS, included after pristine SQLite.
 * No caller-supplied SQL/path, WAL, private SHM, or application database route. */
#include "swarm_lease.h"

#define SL_MAIN "instance_lease.db"
#define SL_JOURNAL "instance_lease.db-journal"
#define SL_VIRTUAL "/swarm-lease"
#define SL_VIRTUAL_JOURNAL "/swarm-lease-journal"

struct SwarmLease {
    sqlite3_vfs vfs;
    sqlite3_io_methods main_methods;
    sqlite3_io_methods journal_methods;
    sqlite3 *db;
    int parent;
    int main_fd;
    int journal_fd;
    int journal_present;
    int created_main;
    int main_files;
    int journal_files;
    int failed;
    int closing;
    int read_only;
    int close_error;
    int close_uncertain;
    struct stat main_identity;
    struct stat journal_identity;
    char vfs_name[64];
    SwarmLeaseValidate validate_scope;
    void *scope_context;
#ifdef SWARM_GUARD_TEST
    SwarmLeaseTestFault *test_fault;
#endif
};

typedef struct SwarmLeaseFile {
    unixFile file;
    SwarmLease *lease;
    int journal;
    int read_only;
    int sync_parent;
} SwarmLeaseFile;

#ifdef SWARM_GUARD_TEST
/* Test-build-only hook installed once before NIF callers run. Only the exact fd
 * in the active thread-local lease close is injected; unrelated closes pass
 * straight through. The real close runs once, then EIO models a consumed-fd error. */
static int (*sl_test_original_close)(int);
static _Thread_local SwarmLease *sl_test_closing_lease;
static _Thread_local int sl_test_closing_fd = -1;
static _Thread_local int sl_test_closing_site;

static int sl_test_report_result(SwarmLease *l, int rc, int site) {
    if (site > 0 && l && l->test_fault && l->test_fault->site == site) {
        l->test_fault->site = 0;
        l->test_fault->hits++;
        if (rc == 0) errno = EIO;
        return -1;
    }
    return rc;
}

static int sl_test_close_hook(int fd) {
    int rc = sl_test_original_close(fd);
    if (fd == sl_test_closing_fd)
        return sl_test_report_result(sl_test_closing_lease, rc, sl_test_closing_site);
    return rc;
}

int swarm_lease_test_install_close_hook(void) {
    sqlite3_vfs *vfs = sqlite3_vfs_find("unix");
    if (!vfs || !vfs->xGetSystemCall || !vfs->xSetSystemCall) return SQLITE_ERROR;
    sl_test_original_close = (int (*)(int))vfs->xGetSystemCall(vfs, "close");
    if (!sl_test_original_close) return SQLITE_ERROR;
    return vfs->xSetSystemCall(vfs, "close", (sqlite3_syscall_ptr)sl_test_close_hook);
}

void swarm_lease_test_restore_close_hook(void) {
    sqlite3_vfs *vfs = sqlite3_vfs_find("unix");
    if (vfs && sl_test_original_close)
        vfs->xSetSystemCall(vfs, "close", (sqlite3_syscall_ptr)sl_test_original_close);
}

#endif

/* Every lease-owned descriptor close returns through this helper. The fd is
 * consumed exactly once regardless of the OS result; never probe or retry it. */
static int sl_close_owned_fd(SwarmLease *l, int fd, int site) {
#ifdef SWARM_GUARD_TEST
    SwarmLease *prior_lease = sl_test_closing_lease;
    int prior_fd = sl_test_closing_fd;
    int prior_site = sl_test_closing_site;
    sl_test_closing_lease = l;
    sl_test_closing_fd = fd;
    sl_test_closing_site = site;
#else
    (void)site;
#endif
    int rc = osClose(fd);
#ifdef SWARM_GUARD_TEST
    sl_test_closing_lease = prior_lease;
    sl_test_closing_fd = prior_fd;
    sl_test_closing_site = prior_site;
#endif
    if (rc != 0) {
        l->close_error = 1;
        l->close_uncertain = 1;
        return SQLITE_IOERR_CLOSE;
    }
    return SQLITE_OK;
}

/* Reuse pinned closeUnixFile memory/mmap bookkeeping after taking responsibility
 * for h. It cannot silently close this fd because h is already invalidated. */
static int sl_close_unix_file(SwarmLease *l, sqlite3_file *file, int site) {
    unixFile *p = (unixFile *)file;
    int fd = p->h;
    p->h = -1;
    int rc = fd >= 0 ? sl_close_owned_fd(l, fd, site) : SQLITE_OK;
    closeUnixFile(file);
    return rc;
}

static int sl_private(const struct stat *st) {
    return S_ISREG(st->st_mode) && st->st_uid == geteuid() &&
      st->st_nlink == 1 && (st->st_mode & 07777) == 0600;
}

static int sl_same(const struct stat *a, const struct stat *b) {
    return S_ISREG(a->st_mode) && S_ISREG(b->st_mode) && a->st_dev == b->st_dev &&
      a->st_ino == b->st_ino && a->st_uid == b->st_uid;
}

static int sl_role(int parent, const char *name, int fd, const struct stat *identity) {
    struct stat held, named;
    return fd >= 0 && fstat(fd, &held) == 0 && sl_private(&held) && sl_same(&held, identity) &&
      fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && sl_private(&named) && sl_same(&held, &named);
}

static int sl_absent(int parent, const char *name) {
    struct stat st;
    return fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT;
}

static int sl_validate(SwarmLease *l) {
    if (l->failed || l->close_uncertain || !l->validate_scope(l->scope_context) ||
        !sl_role(l->parent, SL_MAIN, l->main_fd, &l->main_identity) ||
        !sl_absent(l->parent, SL_MAIN "-wal") || !sl_absent(l->parent, SL_MAIN "-shm")) {
        l->failed = 1;
        return 0;
    }
    if (l->journal_present ?
          !sl_role(l->parent, SL_JOURNAL, l->journal_fd, &l->journal_identity) :
          !sl_absent(l->parent, SL_JOURNAL)) {
        l->failed = 1;
        return 0;
    }
    return 1;
}

static int sl_file_ready(SwarmLeaseFile *file) {
    SwarmLease *l = file->lease;
    if (!l->closing) return sl_validate(l);
    /* Teardown may use only already-open admitted objects after namespace loss. */
    struct stat actual;
    const struct stat *identity = file->journal ? &l->journal_identity : &l->main_identity;
    return fstat(file->file.h, &actual) == 0 && sl_private(&actual) && sl_same(&actual, identity);
}

static int sl_read(sqlite3_file *file, void *data, int count, sqlite3_int64 offset) {
    if (!sl_file_ready((SwarmLeaseFile *)file)) return SQLITE_IOERR_READ;
    return unixRead(file, data, count, offset);
}

static int sl_write(sqlite3_file *file, const void *data, int count, sqlite3_int64 offset) {
    if (((SwarmLeaseFile *)file)->read_only) return SQLITE_READONLY;
    if (!sl_file_ready((SwarmLeaseFile *)file)) return SQLITE_IOERR_WRITE;
    return unixWrite(file, data, count, offset);
}

static int sl_truncate(sqlite3_file *file, sqlite3_int64 size) {
    if (((SwarmLeaseFile *)file)->read_only) return SQLITE_READONLY;
    if (!sl_file_ready((SwarmLeaseFile *)file)) return SQLITE_IOERR_TRUNCATE;
    return unixTruncate(file, size);
}

static int sl_sync(sqlite3_file *file, int flags) {
    SwarmLeaseFile *f = (SwarmLeaseFile *)file;
    if (!sl_file_ready(f)) return SQLITE_IOERR_FSYNC;
    /* Never allow unixSync to reopen a pathname for directory syncing. */
    f->file.ctrlFlags &= ~UNIXFILE_DIRSYNC;
    int rc = unixSync(file, flags);
    if (rc == SQLITE_OK && f->sync_parent) {
        if (fsync(f->lease->parent)) return SQLITE_IOERR_DIR_FSYNC;
        f->sync_parent = 0;
    }
    return rc;
}

static int sl_file_size(sqlite3_file *file, sqlite3_int64 *size) {
    if (!sl_file_ready((SwarmLeaseFile *)file)) return SQLITE_IOERR_FSTAT;
    return unixFileSize(file, size);
}

static int sl_lock(sqlite3_file *file, int level) {
    if (!sl_file_ready((SwarmLeaseFile *)file)) return SQLITE_IOERR_LOCK;
    return unixLock(file, level);
}

static int sl_control(sqlite3_file *file, int operation, void *argument) {
    SwarmLease *l = ((SwarmLeaseFile *)file)->lease;
    if (operation == SQLITE_FCNTL_HAS_MOVED) {
        *(int *)argument = !sl_role(l->parent, SL_MAIN, l->main_fd, &l->main_identity);
        return SQLITE_OK;
    }
    if (operation == SQLITE_FCNTL_VFS_POINTER || operation == SQLITE_FCNTL_VFSNAME ||
        operation == SQLITE_FCNTL_TEMPFILENAME || operation == SQLITE_FCNTL_PERSIST_WAL)
        return SQLITE_NOTFOUND;
    if (operation == SQLITE_FCNTL_MMAP_SIZE) {
        *(sqlite3_int64 *)argument = 0;
        return SQLITE_OK;
    }
    switch (operation) {
        case SQLITE_FCNTL_LOCKSTATE:
        case SQLITE_FCNTL_LAST_ERRNO:
        case SQLITE_FCNTL_CHUNK_SIZE:
        case SQLITE_FCNTL_POWERSAFE_OVERWRITE:
            return unixFileControl(file, operation, argument);
        case SQLITE_FCNTL_SIZE_HINT:
            if (((SwarmLeaseFile *)file)->read_only) return SQLITE_READONLY;
            if (!sl_file_ready((SwarmLeaseFile *)file)) return SQLITE_IOERR;
            return unixFileControl(file, operation, argument);
        default:
            return SQLITE_NOTFOUND;
    }
}

static int sl_file_close(sqlite3_file *file) {
    SwarmLeaseFile *f = (SwarmLeaseFile *)file;
    SwarmLease *l = f->lease;
    int journal = f->journal;
    int rc;
    if (journal) {
        rc = sl_close_unix_file(l, file, 2);
        l->journal_files--; /* Logical detach; close_uncertain separately owns doubt. */
        return rc;
    }

    unixFile *p = &f->file;
    unixInodeInfo *inode = p->pInode;
    unixEnterMutex();
    /* This lease has one internal main handle, never a pool. Reject an observed
     * sibling/pending descriptor instead of invoking stock unobserved close paths.
     * Hold global before inode mutex throughout unlock/release/owned close. */
    if (!inode) {
        unixLeaveMutex();
        l->close_error = l->close_uncertain = 1;
        return SQLITE_IOERR_CLOSE;
    }
    sqlite3_mutex_enter(inode->pLockMutex);
    int sole = inode->nRef == 1 && inode->pUnused == NULL && inode->pShmNode == NULL;
    sqlite3_mutex_leave(inode->pLockMutex);
    if (!sole) {
        unixLeaveMutex();
        l->close_error = l->close_uncertain = 1;
        return SQLITE_BUSY;
    }
    rc = unixUnlock(file, NO_LOCK);
    if (rc != SQLITE_OK) {
        unixLeaveMutex();
        l->close_error = l->close_uncertain = 1;
        return rc; /* Preserve exclusion and quarantine; do not repeat an unlock. */
    }
    /* With sole ownership and no pending list, these pinned routines perform
     * inode release and bookkeeping without a hidden descriptor close. */
    releaseInodeInfo(p);
    rc = sl_close_unix_file(l, file, 1);
    unixLeaveMutex();
    l->main_files--;
    return rc;
}

static int sl_full_path(sqlite3_vfs *vfs, const char *path, int size, char *out) {
    (void)vfs;
    if (strcmp(path, SL_VIRTUAL) || size <= (int)strlen(SL_VIRTUAL)) return SQLITE_CANTOPEN;
    sqlite3_snprintf(size, out, "%s", SL_VIRTUAL);
    return SQLITE_OK;
}

static int sl_open(sqlite3_vfs *vfs, const char *path, sqlite3_file *file, int flags, int *out_flags) {
    SwarmLease *l = (SwarmLease *)vfs;
    SwarmLeaseFile *f = (SwarmLeaseFile *)file;
    unixFile *p = &f->file;
    int type = flags & 0x0fff00;
    int journal = type == SQLITE_OPEN_MAIN_JOURNAL;
    memset(f, 0, sizeof(*f));
    p->h = -1;
    if (!path || l->closing || !sl_validate(l) ||
        (flags & (SQLITE_OPEN_URI | SQLITE_OPEN_DELETEONCLOSE | SQLITE_OPEN_AUTOPROXY)) ||
        !(flags & (SQLITE_OPEN_READWRITE | SQLITE_OPEN_READONLY)) ||
        (!journal && ((flags & SQLITE_OPEN_READONLY) != (l->read_only ? SQLITE_OPEN_READONLY : 0))) ||
        (journal ? strcmp(path, SL_VIRTUAL_JOURNAL) : type != SQLITE_OPEN_MAIN_DB || strcmp(path, SL_VIRTUAL)) ||
        (journal ? l->journal_files : l->main_files)) return SQLITE_CANTOPEN;

    if (journal && !l->journal_present) {
        if (l->read_only || !(flags & SQLITE_OPEN_CREATE)) return SQLITE_CANTOPEN;
        int fd = openat(l->parent, SL_JOURNAL,
          O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
        if (fd < 0) { l->failed = 1; return SQLITE_CANTOPEN; }
        struct stat st;
        if (fstat(fd, &st) || !sl_private(&st) || sl_same(&st, &l->main_identity)) {
            sl_close_owned_fd(l, fd, 0); l->failed = 1; return SQLITE_CANTOPEN;
        }
        /* Mutation-produced fd/identity is recorded before exposing this role. */
        l->journal_fd = fd; l->journal_identity = st; l->journal_present = 1;
        f->sync_parent = 1;
        if (!sl_validate(l)) return SQLITE_CANTOPEN;
    }
    if (!journal) {
        p->pPreallocatedUnused = sqlite3_malloc64(sizeof(UnixUnusedFd));
        if (!p->pPreallocatedUnused) return SQLITE_NOMEM;
        memset(p->pPreallocatedUnused, 0, sizeof(UnixUnusedFd));
    }
    int fd = fcntl(journal ? l->journal_fd : l->main_fd, F_DUPFD_CLOEXEC, 3);
    if (fd < 0) { sqlite3_free(p->pPreallocatedUnused); p->pPreallocatedUnused = NULL; return SQLITE_CANTOPEN; }
    if (p->pPreallocatedUnused) {
        p->pPreallocatedUnused->fd = fd;
        p->pPreallocatedUnused->flags = flags & (SQLITE_OPEN_READONLY | SQLITE_OPEN_READWRITE);
    }
#ifdef SWARM_GUARD_TEST
    if (!journal && l->test_fault && l->test_fault->site == 3) {
        sl_close_owned_fd(l, fd, 3);
        sqlite3_free(p->pPreallocatedUnused); p->pPreallocatedUnused = NULL;
        return SQLITE_IOERR_ACCESS;
    }
#endif
#if SQLITE_ENABLE_LOCKING_STYLE
    p->openFlags = ((flags & SQLITE_OPEN_READONLY) ? O_RDONLY : O_RDWR) | O_NOFOLLOW | O_LARGEFILE | O_BINARY;
#endif
#if defined(__APPLE__) || SQLITE_ENABLE_LOCKING_STYLE
    struct statfs fs;
    if (fstatfs(fd, &fs)) {
        sl_close_owned_fd(l, fd, 3); sqlite3_free(p->pPreallocatedUnused); p->pPreallocatedUnused = NULL;
        return SQLITE_IOERR_ACCESS;
    }
    if (!strncmp("msdos", fs.f_fstypename, 5) || !strncmp("exfat", fs.f_fstypename, 5)) {
        /* Stock inode discovery writes an empty FAT file even during RO admission. */
        sl_close_owned_fd(l, fd, 3); sqlite3_free(p->pPreallocatedUnused); p->pPreallocatedUnused = NULL;
        return SQLITE_CANTOPEN;
    }
#endif
    /* NOLOCK skips stock pathname verify; attach the main inode explicitly below. */
    int rc = fillInUnixFile(vfs, fd, file, path, UNIXFILE_NOLOCK |
      ((flags & SQLITE_OPEN_READONLY) ? UNIXFILE_RDONLY : 0));
    if (rc != SQLITE_OK) {
        sqlite3_free(p->pPreallocatedUnused); p->pPreallocatedUnused = NULL; p->h = -1;
        /* NOLOCK cannot fail on supported Unix here. If that changes, its
         * internal close result is unknowable: quarantine rather than claim it. */
        l->close_error = l->close_uncertain = 1;
        return rc;
    }
    if (!journal) {
        unixEnterMutex();
        rc = findInodeInfo(p, &p->pInode);
        unixLeaveMutex();
        if (rc != SQLITE_OK) {
            sl_close_unix_file(l, file, 3);
            return rc;
        }
        p->ctrlFlags &= ~UNIXFILE_NOLOCK;
    }
#if SQLITE_MAX_MMAP_SIZE > 0
    p->mmapSizeMax = 0;
#endif
    f->lease = l; f->journal = journal; f->read_only = (flags & SQLITE_OPEN_READONLY) != 0;
    p->pMethod = journal ? &l->journal_methods : &l->main_methods;
    if (journal) l->journal_files++; else l->main_files++;
    if (out_flags) *out_flags = flags;
    return SQLITE_OK;
}

static int sl_access(sqlite3_vfs *vfs, const char *path, int flags, int *out) {
    (void)flags;
    SwarmLease *l = (SwarmLease *)vfs;
    if (!path || (!l->closing && !sl_validate(l))) return SQLITE_IOERR_ACCESS;
    if (!strcmp(path, SL_VIRTUAL)) { *out = 1; return SQLITE_OK; }
    if (!strcmp(path, SL_VIRTUAL_JOURNAL)) {
        if (l->journal_present && !sl_role(l->parent, SL_JOURNAL, l->journal_fd, &l->journal_identity))
            return SQLITE_IOERR_ACCESS;
        *out = l->journal_present; return SQLITE_OK;
    }
    if (!strcmp(path, SL_VIRTUAL "-wal") || !strcmp(path, SL_VIRTUAL "-shm")) {
        /* Actual absence was admitted and is rechecked by sl_validate. */
        *out = 0; return SQLITE_OK;
    }
    return SQLITE_IOERR_ACCESS;
}

static int sl_delete(sqlite3_vfs *vfs, const char *path, int sync_directory) {
    SwarmLease *l = (SwarmLease *)vfs;
    if (l->read_only || !path || strcmp(path, SL_VIRTUAL_JOURNAL) || l->journal_files ||
        !l->journal_present || !sl_role(l->parent, SL_JOURNAL, l->journal_fd, &l->journal_identity) ||
        (!l->closing && !sl_validate(l))) return SQLITE_IOERR_DELETE;
    /* Exact observed role under a held parent; not atomic compare-and-unlink. */
    if (unlinkat(l->parent, SL_JOURNAL, 0)) return SQLITE_IOERR_DELETE;
    int fd = l->journal_fd;
    l->journal_fd = -1; l->journal_present = 0;
    if (sl_close_owned_fd(l, fd, 0) != SQLITE_OK) return SQLITE_IOERR_CLOSE;
    if (sync_directory && fsync(l->parent)) return SQLITE_IOERR_DIR_FSYNC;
    return SQLITE_OK;
}

static int sl_admit_file(SwarmLease *l) {
    if (!sl_absent(l->parent, SL_MAIN "-wal") || !sl_absent(l->parent, SL_MAIN "-shm"))
        return SQLITE_CANTOPEN;
    struct stat named;
    if (fstatat(l->parent, SL_MAIN, &named, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!sl_private(&named)) return SQLITE_CANTOPEN;
        l->main_fd = openat(l->parent, SL_MAIN, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    } else if (errno == ENOENT) {
        if (!sl_absent(l->parent, SL_JOURNAL)) return SQLITE_CANTOPEN;
        l->main_fd = openat(l->parent, SL_MAIN,
          O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
        l->created_main = l->main_fd >= 0;
    } else return SQLITE_CANTOPEN;
    if (l->main_fd < 0 || fstat(l->main_fd, &l->main_identity) || !sl_private(&l->main_identity) ||
        (!l->created_main && !sl_same(&named, &l->main_identity))) return SQLITE_CANTOPEN;
    if (l->main_identity.st_size) {
        unsigned char header[100];
        if (pread(l->main_fd, header, sizeof(header), 0) != sizeof(header) ||
            memcmp(header, "SQLite format 3\0", 16) || header[18] != 1 || header[19] != 1)
            return SQLITE_NOTADB;
    }
    if (fstatat(l->parent, SL_JOURNAL, &named, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!sl_private(&named) || sl_same(&named, &l->main_identity)) return SQLITE_CANTOPEN;
        l->journal_fd = openat(l->parent, SL_JOURNAL, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (l->journal_fd < 0 || fstat(l->journal_fd, &l->journal_identity) ||
            !sl_private(&l->journal_identity) || !sl_same(&named, &l->journal_identity)) return SQLITE_CANTOPEN;
        l->journal_present = 1;
    } else if (errno != ENOENT) return SQLITE_CANTOPEN;
    if (l->created_main && fsync(l->parent)) return SQLITE_IOERR_DIR_FSYNC;
    return sl_validate(l) ? SQLITE_OK : SQLITE_CANTOPEN;
}

static int sl_exec(SwarmLease *l, const char *sql) {
    return sqlite3_exec(l->db, sql, NULL, NULL, NULL);
}

static int sl_delete_mode(SwarmLease *l) {
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(l->db, "PRAGMA journal_mode=DELETE", -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        rc = sqlite3_step(stmt);
        if (rc == SQLITE_ROW) {
            const unsigned char *mode = sqlite3_column_text(stmt, 0);
            rc = mode && !strcmp((const char *)mode, "delete") ? SQLITE_OK : SQLITE_ERROR;
        }
    }
    int final = sqlite3_finalize(stmt);
    return rc == SQLITE_OK ? final : rc;
}

static int sl_scalar(SwarmLease *l, const char *sql, int *value) {
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(l->db, sql, -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        rc = sqlite3_step(stmt);
        if (rc == SQLITE_ROW) { *value = sqlite3_column_int(stmt, 0); rc = SQLITE_OK; }
    }
    int final = sqlite3_finalize(stmt);
    return rc == SQLITE_OK ? final : rc;
}

static int sl_compatible_empty(SwarmLease *l) {
    int schema = -1, app = -1, version = -1;
    int rc = sl_scalar(l, "SELECT EXISTS(SELECT 1 FROM sqlite_schema)", &schema);
    if (rc == SQLITE_OK) rc = sl_scalar(l, "PRAGMA application_id", &app);
    if (rc == SQLITE_OK) rc = sl_scalar(l, "PRAGMA user_version", &version);
    if (rc != SQLITE_OK) return rc;
    return schema == 0 && app == 0 && (version == 0 || version == 1) ? SQLITE_OK : SQLITE_NOTADB;
}

static int sl_progress(void *context) {
    SwarmLease *l = context;
    return !l->closing && !l->validate_scope(l->scope_context);
}

static int sl_open_db(SwarmLease *l, int read_only) {
    l->read_only = read_only;
    int rc = sqlite3_vfs_register(&l->vfs, 0);
    if (rc != SQLITE_OK) return rc;
    rc = sqlite3_open_v2(SL_VIRTUAL, &l->db,
      read_only ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE, l->vfs_name);
    sqlite3_vfs_unregister(&l->vfs);
    if (rc == SQLITE_OK) {
        sqlite3_busy_timeout(l->db, 0);
        sqlite3_limit(l->db, SQLITE_LIMIT_LENGTH, 1024 * 1024);
        sqlite3_limit(l->db, SQLITE_LIMIT_SQL_LENGTH, 65536);
        sqlite3_limit(l->db, SQLITE_LIMIT_COLUMN, 512);
        sqlite3_limit(l->db, SQLITE_LIMIT_EXPR_DEPTH, 128);
        sqlite3_limit(l->db, SQLITE_LIMIT_ATTACHED, 0);
        sqlite3_progress_handler(l->db, 1000, sl_progress, l);
    }
    return rc;
}

static int sl_acquire_impl(int parent, SwarmLeaseValidate validate, void *context,
                           void *test_fault, SwarmLease **out) {
    SwarmLease *l = sqlite3_malloc64(sizeof(*l));
    if (!l) return SQLITE_NOMEM;
    memset(l, 0, sizeof(*l));
    *out = l; /* Scope graph owns every partial acquisition before further IO. */
    l->parent = parent; l->main_fd = l->journal_fd = -1;
    l->validate_scope = validate; l->scope_context = context;
#ifdef SWARM_GUARD_TEST
    l->test_fault = test_fault;
#else
    (void)test_fault;
#endif
    int rc = sl_admit_file(l);
    if (rc != SQLITE_OK) return rc;
    l->vfs = *sqlite3_vfs_find("unix");
    l->vfs.pNext = NULL; l->vfs.szOsFile = sizeof(SwarmLeaseFile);
    l->vfs.pAppData = (void *)&posixIoFinder;
    l->vfs.xOpen = sl_open; l->vfs.xFullPathname = sl_full_path;
    l->vfs.xAccess = sl_access; l->vfs.xDelete = sl_delete;
    l->main_methods = posixIoMethods; l->journal_methods = nolockIoMethods;
    sqlite3_io_methods *methods[] = {&l->main_methods, &l->journal_methods};
    for (int i = 0; i < 2; i++) {
        methods[i]->iVersion = 1; /* WAL/SHM and mapped-file APIs unavailable. */
        methods[i]->xClose = sl_file_close; methods[i]->xRead = sl_read; methods[i]->xWrite = sl_write;
        methods[i]->xTruncate = sl_truncate; methods[i]->xSync = sl_sync;
        methods[i]->xFileSize = sl_file_size; methods[i]->xFileControl = sl_control;
        methods[i]->xShmMap = NULL; methods[i]->xShmLock = NULL;
        methods[i]->xShmBarrier = NULL; methods[i]->xShmUnmap = NULL;
        methods[i]->xFetch = NULL; methods[i]->xUnfetch = NULL;
    }
    l->main_methods.xLock = sl_lock;
    unsigned char random[16]; sqlite3_randomness(sizeof(random), random);
    l->vfs_name[0] = 'l';
    for (unsigned i = 0; i < sizeof(random); i++) sqlite3_snprintf(3, l->vfs_name + 1 + 2*i, "%02x", random[i]);
    l->vfs.zName = l->vfs_name;
    /* Validate schema read-only first; unknown hot-journal recovery must not write. */
    rc = sl_open_db(l, 1);
    if (rc == SQLITE_OK) rc = sl_compatible_empty(l);
    if (rc != SQLITE_OK) return rc;
    rc = sqlite3_close(l->db);
    if (rc != SQLITE_OK) return rc;
    l->db = NULL;
    if (l->main_files || l->journal_files) return SQLITE_BUSY;
    if (l->close_uncertain) return SQLITE_IOERR_CLOSE;
    rc = sl_open_db(l, 0);
    if (rc == SQLITE_OK) rc = sl_exec(l, "PRAGMA temp_store=MEMORY; PRAGMA synchronous=FULL; BEGIN EXCLUSIVE");
    if (rc == SQLITE_OK) rc = sl_compatible_empty(l);
    if (rc == SQLITE_OK) rc = sl_delete_mode(l);
    if (rc == SQLITE_OK && l->main_identity.st_size == 0)
        rc = sl_exec(l, "PRAGMA user_version=1; COMMIT; BEGIN EXCLUSIVE");
    if (rc == SQLITE_OK) rc = swarm_lease_assert(l);
    return rc;
}

int swarm_lease_acquire(int parent, SwarmLeaseValidate validate, void *context, SwarmLease **out) {
    return sl_acquire_impl(parent, validate, context, NULL, out);
}

#ifdef SWARM_GUARD_TEST
int swarm_lease_acquire_test(int parent, SwarmLeaseValidate validate, void *context,
                             SwarmLeaseTestFault *fault, SwarmLease **out) {
    return sl_acquire_impl(parent, validate, context, fault, out);
}
#endif

int swarm_lease_assert(SwarmLease *l) {
    if (!l || !l->db || !sl_validate(l) || sqlite3_get_autocommit(l->db)) return SQLITE_MISUSE;
    sqlite3_file *file = NULL;
    if (sqlite3_file_control(l->db, "main", SQLITE_FCNTL_FILE_POINTER, &file) != SQLITE_OK || !file)
        return SQLITE_IOERR;
    unixFile *p = (unixFile *)file;
    struct stat actual;
    if (p->pMethod != &l->main_methods || !p->pInode || !p->pPreallocatedUnused ||
        p->eFileLock != EXCLUSIVE_LOCK || fstat(p->h, &actual) ||
        !sl_private(&actual) || !sl_same(&actual, &l->main_identity)) return SQLITE_IOERR;
    return SQLITE_OK;
}

int swarm_lease_identity(SwarmLease *l, struct stat *identity) {
    int rc = swarm_lease_assert(l);
    if (rc == SQLITE_OK) *identity = l->main_identity;
    return rc;
}

int swarm_lease_active(SwarmLease *l) {
    return l && (l->db || l->main_files || l->journal_files || l->close_uncertain);
}

int swarm_lease_close(SwarmLease *l) {
    if (!l) return SQLITE_OK;
    l->closing = 1;
    if (l->db) {
        /* No external statement API exists. Finalize defensively on failed init. */
        sqlite3_stmt *stmt;
        while ((stmt = sqlite3_next_stmt(l->db, NULL)) != NULL) sqlite3_finalize(stmt);
        int rc = sqlite3_close(l->db);
        if (rc != SQLITE_OK) return rc;
        l->db = NULL;
    }
    if (l->main_files || l->journal_files) return SQLITE_BUSY;
    if (l->close_uncertain) return SQLITE_IOERR_CLOSE;
    if (l->journal_fd >= 0) {
        int fd = l->journal_fd; l->journal_fd = -1;
        if (sl_close_owned_fd(l, fd, 0) != SQLITE_OK) return SQLITE_IOERR_CLOSE;
    }
    if (l->main_fd >= 0) {
        int fd = l->main_fd; l->main_fd = -1;
        if (sl_close_owned_fd(l, fd, 0) != SQLITE_OK) return SQLITE_IOERR_CLOSE;
    }
    return l->close_error ? SQLITE_IOERR_CLOSE : SQLITE_OK;
}

void swarm_lease_free(SwarmLease *l) {
    if (l && !swarm_lease_active(l) && l->main_fd < 0 && l->journal_fd < 0) sqlite3_free(l);
}
