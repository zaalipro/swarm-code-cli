/* Copy an owned SQLite main/WAL pair without asking SQLite to open the source.
 * Lock offsets match the project's pinned SQLite Unix VFS (SQLite 3.53.3).
 * The caller owns all output creation and cleanup, including partial failures.
 */
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define COPY_BUFFER_SIZE 65536
#define PENDING_BYTE ((off_t)0x40000000)
#define RESERVED_BYTE (PENDING_BYTE + 1)
#define SHARED_FIRST (PENDING_BYTE + 2)
#define SHARED_SIZE ((off_t)510)
#define SHM_WRITE_FIRST ((off_t)120)
#define SHM_WRITE_COUNT ((off_t)3)
#define SHM_DMS ((off_t)128)

struct identity {
    uint64_t device;
    uint64_t inode;
    bool present;
};

struct options {
    const char *source_directory;
    const char *basename;
    struct identity source_directory_id;
    struct identity source[3];
    struct identity output[2];
    struct identity output_directory_id;
    uint64_t uid;
    uint64_t timeout_ms;
    uint64_t byte_cap;
};

struct file {
    int fd;
    const char *name;
    struct identity id;
    uint64_t size;
};

static volatile sig_atomic_t cancelled;
static uint64_t deadline_ns;

static void cancel_signal(int signal_number) {
    (void)signal_number;
    cancelled = 1;
}

static bool parse_number(const char *text, uint64_t *value) {
    uint64_t number = 0;
    if (*text == '\0' || (text[0] == '0' && text[1] != '\0')) return false;
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        if (*p < '0' || *p > '9') return false;
        unsigned digit = *p - '0';
        if (number > (UINT64_MAX - digit) / 10) return false;
        number = number * 10 + digit;
    }
    *value = number;
    return true;
}

static bool parse_identity(char **args, bool optional, struct identity *id) {
    if (optional && strcmp(args[0], "-") == 0 && strcmp(args[1], "-") == 0) {
        *id = (struct identity){0, 0, false};
        return true;
    }
    id->present = true;
    return parse_number(args[0], &id->device) && parse_number(args[1], &id->inode);
}

static bool parse_options(int argc, char **argv, struct options *options) {
    if (argc != 21 || strcmp(argv[1], "v1") != 0) return false;
    size_t directory_length = strlen(argv[2]);
    size_t name_length = strlen(argv[3]);
    if (argv[2][0] != '/' || directory_length > 16384 || name_length < 1 ||
        name_length > 255 || strchr(argv[3], '/') || strcmp(argv[3], ".") == 0 ||
        strcmp(argv[3], "..") == 0) return false;
    options->source_directory = argv[2];
    options->basename = argv[3];
    return parse_identity(argv + 4, false, &options->source_directory_id) &&
           parse_number(argv[6], &options->uid) &&
           parse_identity(argv + 7, false, &options->source[0]) &&
           parse_identity(argv + 9, true, &options->source[1]) &&
           parse_identity(argv + 11, true, &options->source[2]) &&
           parse_identity(argv + 13, false, &options->output[0]) &&
           parse_identity(argv + 15, false, &options->output[1]) &&
           parse_identity(argv + 17, false, &options->output_directory_id) &&
           parse_number(argv[19], &options->timeout_ms) && options->timeout_ms >= 1 &&
           options->timeout_ms <= 300000 && parse_number(argv[20], &options->byte_cap) &&
           options->byte_cap >= 1 && options->byte_cap <= INT64_MAX;
}

static bool monotonic_ns(uint64_t *value) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
        (uint64_t)now.tv_sec > (UINT64_MAX - (uint64_t)now.tv_nsec) / 1000000000) return false;
    *value = (uint64_t)now.tv_sec * 1000000000 + (uint64_t)now.tv_nsec;
    return true;
}

/* stdin is a liveness channel. Both EOF and unexpected data cancel the copy. */
static bool still_running(void) {
    uint64_t now;
    if (cancelled || !monotonic_ns(&now) || now >= deadline_ns) return false;
    struct pollfd control = {STDIN_FILENO, POLLIN, 0};
    int result = poll(&control, 1, 0);
    return result == 0;
}

static bool start_control(uint64_t timeout_ms) {
    uint64_t now;
    if (!monotonic_ns(&now) || now > UINT64_MAX - timeout_ms * 1000000) return false;
    deadline_ns = now + timeout_ms * 1000000;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = cancel_signal;
    if (sigemptyset(&action.sa_mask) != 0 || sigaction(SIGTERM, &action, NULL) != 0 ||
        sigaction(SIGINT, &action, NULL) != 0 || sigaction(SIGHUP, &action, NULL) != 0) return false;
    action.sa_handler = SIG_IGN;
    return sigaction(SIGPIPE, &action, NULL) == 0 && still_running();
}

static bool same_identity(const struct stat *status, struct identity id) {
    return id.present && (uint64_t)status->st_dev == id.device &&
           (uint64_t)status->st_ino == id.inode;
}

static bool identities_equal(struct identity a, struct identity b) {
    return a.present && b.present && a.device == b.device && a.inode == b.inode;
}

static bool regular_status(const struct stat *status, struct identity id, uint64_t uid) {
    return same_identity(status, id) && S_ISREG(status->st_mode) &&
           (status->st_mode & 07777) == 0600 && (uint64_t)status->st_uid == uid &&
           status->st_size >= 0 && (uint64_t)status->st_size <= INT64_MAX;
}

static bool check_directory(int fd, struct identity id, uint64_t uid) {
    struct stat status;
    return fstat(fd, &status) == 0 && same_identity(&status, id) &&
           S_ISDIR(status.st_mode) && (uint64_t)status.st_uid == uid &&
           (status.st_mode & 07777) == 0700;
}

static bool check_file(int directory, struct file *file, uint64_t uid, bool check_size) {
    struct stat descriptor, path;
    if (!file->id.present) {
        return fstatat(directory, file->name, &path, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
    }
    return fstat(file->fd, &descriptor) == 0 &&
           fstatat(directory, file->name, &path, AT_SYMLINK_NOFOLLOW) == 0 &&
           regular_status(&descriptor, file->id, uid) && regular_status(&path, file->id, uid) &&
           (!check_size || ((uint64_t)descriptor.st_size == file->size &&
                            (uint64_t)path.st_size == file->size));
}

static bool open_file(int directory, struct file *file, uint64_t uid, bool output) {
    if (!file->id.present) return check_file(directory, file, uid, false);
    file->fd = openat(directory, file->name,
                      (output ? O_WRONLY : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (file->fd < 0 || !check_file(directory, file, uid, output)) return false;
    return true;
}

static bool no_journal(int directory, const char *name) {
    struct stat status;
    return fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
}

static bool set_lock(int fd, short type, off_t offset, off_t length) {
    struct flock lock;
    memset(&lock, 0, sizeof(lock));
    lock.l_type = type;
    lock.l_whence = SEEK_SET;
    lock.l_start = offset;
    lock.l_len = length;
    return still_running() && fcntl(fd, F_SETLK, &lock) == 0;
}

static bool lock_main_shared(int fd) {
    /* SQLite's pending-byte handshake prevents barging past a pending writer. */
    return set_lock(fd, F_RDLCK, PENDING_BYTE, 1) &&
           set_lock(fd, F_RDLCK, SHARED_FIRST, SHARED_SIZE) &&
           set_lock(fd, F_UNLCK, PENDING_BYTE, 1);
}

static bool lock_main_exclusive(int fd) {
    return set_lock(fd, F_WRLCK, RESERVED_BYTE, 1) &&
           set_lock(fd, F_WRLCK, PENDING_BYTE, 1) &&
           set_lock(fd, F_WRLCK, SHARED_FIRST, SHARED_SIZE);
}

static bool lock_shm(int fd) {
    /* Match SQLite's DMS state discrimination before choosing our lock mode.
     * An exclusive holder may be initializing SHM: refuse even if it releases
     * its lock just after this query, rather than joining its incomplete state.
     * A shared holder can be joined. With no holder, retain exclusive DMS for
     * the entire copy; unlike SQLite, we never initialize or truncate SHM.
     */
    struct flock state;
    memset(&state, 0, sizeof(state));
    state.l_type = F_WRLCK;
    state.l_whence = SEEK_SET;
    state.l_start = SHM_DMS;
    state.l_len = 1;
    if (!still_running() || fcntl(fd, F_GETLK, &state) != 0) return false;
    if (state.l_type == F_UNLCK) {
        if (!set_lock(fd, F_WRLCK, SHM_DMS, 1)) return false;
    } else if (state.l_type == F_RDLCK) {
        if (!set_lock(fd, F_RDLCK, SHM_DMS, 1)) return false;
    } else {
        return false;
    }
    /* Leave reader slots 123..127 alone: holding those induces SQLITE_PROTOCOL. */
    return set_lock(fd, F_WRLCK, SHM_WRITE_FIRST, SHM_WRITE_COUNT);
}

static bool record_size(struct file *file) {
    if (!file->id.present) return true;
    struct stat status;
    if (fstat(file->fd, &status) != 0 || status.st_size < 0 ||
        (uint64_t)status.st_size > INT64_MAX) return false;
    file->size = (uint64_t)status.st_size;
    return true;
}

static bool copy_file(struct file *source, struct file *destination) {
    unsigned char buffer[COPY_BUFFER_SIZE];
    uint64_t copied = 0;
    while (copied < source->size) {
        if (!still_running()) return false;
        size_t wanted = source->size - copied < sizeof(buffer) ?
                        (size_t)(source->size - copied) : sizeof(buffer);
        ssize_t count = pread(source->fd, buffer, wanted, (off_t)copied);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        size_t written = 0;
        while (written < (size_t)count) {
            if (!still_running()) return false;
            ssize_t part = pwrite(destination->fd, buffer + written, (size_t)count - written,
                                  (off_t)(copied + written));
            if (part < 0 && errno == EINTR) continue;
            if (part <= 0) return false;
            written += (size_t)part;
        }
        copied += (uint64_t)count;
    }
    destination->size = copied;
    return still_running();
}

static bool sync_file(int fd) {
    while (still_running()) {
        if (fsync(fd) == 0) return still_running();
        if (errno != EINTR) return false;
    }
    return false;
}

static bool final_directories(int source_fd, int output_fd, const struct options *options) {
    struct stat source_path, output_path;
    return check_directory(source_fd, options->source_directory_id, options->uid) &&
           check_directory(output_fd, options->output_directory_id, options->uid) &&
           lstat(options->source_directory, &source_path) == 0 &&
           same_identity(&source_path, options->source_directory_id) && S_ISDIR(source_path.st_mode) &&
           lstat(".", &output_path) == 0 && same_identity(&output_path, options->output_directory_id);
}

static bool write_success(uint64_t main_size, uint64_t wal_size, bool has_wal) {
    char line[128];
    int length = snprintf(line, sizeof(line), "snapshot-v1 %" PRIu64 " %" PRIu64 " %d\n",
                          main_size, wal_size, has_wal ? 1 : 0);
    if (length < 0 || (size_t)length >= sizeof(line) || !still_running()) return false;
    ssize_t written;
    do {
        written = write(STDOUT_FILENO, line, (size_t)length);
    } while (written < 0 && errno == EINTR && still_running());
    return written == length;
}

int main(int argc, char **argv) {
    struct options options;
    memset(&options, 0, sizeof(options));
    if (!parse_options(argc, argv, &options) || !start_control(options.timeout_ms)) return 2;

    char wal_name[260], shm_name[260], journal_name[264];
    (void)snprintf(wal_name, sizeof(wal_name), "%s-wal", options.basename);
    (void)snprintf(shm_name, sizeof(shm_name), "%s-shm", options.basename);
    (void)snprintf(journal_name, sizeof(journal_name), "%s-journal", options.basename);
    struct file source[3] = {{-1, options.basename, options.source[0], 0},
                             {-1, wal_name, options.source[1], 0},
                             {-1, shm_name, options.source[2], 0}};
    struct file output[2] = {{-1, "snapshot.db", options.output[0], 0},
                             {-1, "snapshot.db-wal", options.output[1], 0}};
    int source_directory = -1, output_directory = -1, main_lock = -1, shm_lock = -1;
    int result = 2;

    /* Validate all borrowed objects before obtaining locks or writing outputs. */
    if (identities_equal(output[0].id, output[1].id)) goto done;
    for (size_t i = 0; i < 2; ++i) {
        for (size_t j = 0; j < 3; ++j) {
            if (identities_equal(output[i].id, source[j].id)) goto done;
        }
    }
    for (size_t i = 0; i < 3; ++i) {
        for (size_t j = i + 1; j < 3; ++j) {
            if (identities_equal(source[i].id, source[j].id)) goto done;
        }
    }
    source_directory = open(options.source_directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    output_directory = open(".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (source_directory < 0 || output_directory < 0 ||
        !final_directories(source_directory, output_directory, &options)) goto done;
    for (size_t i = 0; i < 3; ++i) {
        if (!open_file(source_directory, &source[i], options.uid, false)) goto done;
    }
    for (size_t i = 0; i < 2; ++i) {
        if (!open_file(output_directory, &output[i], options.uid, true)) goto done;
    }
    if (!no_journal(source_directory, journal_name)) goto done;

    /* Both main descriptors stay open: closing either releases POSIX inode locks.
     * Writable source descriptors are used exclusively for fcntl, never byte IO.
     */
    main_lock = openat(source_directory, options.basename, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat lock_status;
    if (main_lock < 0 || fstat(main_lock, &lock_status) != 0 ||
        !regular_status(&lock_status, source[0].id, options.uid) || !lock_main_shared(main_lock)) goto done;
    if (source[1].id.present && source[2].id.present) {
        shm_lock = openat(source_directory, shm_name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (shm_lock < 0 || fstat(shm_lock, &lock_status) != 0 ||
            !regular_status(&lock_status, source[2].id, options.uid) || !lock_shm(shm_lock)) goto done;
    } else if (!lock_main_exclusive(main_lock)) {
        goto done;
    }

    for (size_t i = 0; i < 3; ++i) {
        if (!record_size(&source[i]) || !check_file(source_directory, &source[i], options.uid, true)) goto done;
    }
    if (!no_journal(source_directory, journal_name) || source[0].size > options.byte_cap ||
        source[1].size > options.byte_cap - source[0].size) goto done;
    if (!copy_file(&source[0], &output[0]) ||
        (source[1].id.present && !copy_file(&source[1], &output[1]))) goto done;
    if (!sync_file(output[0].fd) || !sync_file(output[1].fd)) goto done;
    for (size_t i = 0; i < 3; ++i) {
        if (!check_file(source_directory, &source[i], options.uid, true)) goto done;
    }
    for (size_t i = 0; i < 2; ++i) {
        if (!check_file(output_directory, &output[i], options.uid, true)) goto done;
    }
    if (!no_journal(source_directory, journal_name) ||
        !final_directories(source_directory, output_directory, &options) ||
        !write_success(source[0].size, source[1].size, source[1].id.present)) goto done;
    result = 0;

done:
    /* No unlink/truncate: the caller owns even partially filled output inodes.
     * Retain every source descriptor until copying and final checks have ended.
     */
    if (shm_lock >= 0) (void)close(shm_lock);
    if (main_lock >= 0) (void)close(main_lock);
    for (size_t i = 0; i < 3; ++i) if (source[i].fd >= 0) (void)close(source[i].fd);
    for (size_t i = 0; i < 2; ++i) if (output[i].fd >= 0) (void)close(output[i].fd);
    if (source_directory >= 0) (void)close(source_directory);
    if (output_directory >= 0) (void)close(output_directory);
    return result;
}
