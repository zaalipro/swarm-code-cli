/* Production directory capability primitive. Included in sqlite3_nif.c.
 * No SQLite file, Ready, canonical-path policy, mkdir, chmod, or unlink API. */
#if !defined(_WIN32)
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include "swarm_lease.h"
#include "swarm_binding.h"

#define SD_MAX_NODES 128
#define SD_MAX_SCOPES 128
#define SD_MAX_PATH 4096
#define SD_MAX_NAME 255

typedef struct sd_node {
    int fd;
    int parent;
    int private_leaf;
    struct stat identity;
    char name[SD_MAX_NAME + 1];
} sd_node;

typedef struct sd_control {
    ErlNifMutex *io_mutex;
    ErlNifPid owner;
    _Atomic unsigned refs;
    _Atomic int revoked;
    _Atomic int queued;
    _Atomic int terminal; /* 0 live/pending, 1 closed, 2 close failed */
    int node_count;
    int runtime_node;
    int data_node;
    int locked;
    int close_error;
    SwarmLease *lease;
    int lease_attempted;
    _Atomic int lease_required;
    int lease_close_failed;
    int lease_quarantined;
    sqlite3 *binding_quarantine_db[8];
    SbBinding *binding_vfs;
    unsigned binding_connections;
    int binding_quarantined;
    char binding_name[64];
    int binding_fd;
    int binding_attempted;
    struct stat binding_identity;
#ifdef SWARM_GUARD_TEST
    SwarmLeaseTestFault lease_test_fault;
#endif
    sd_node nodes[SD_MAX_NODES];
    struct sd_control *queue_next;
} sd_control;

typedef struct sd_scope {
    sd_control *control;
    ErlNifMonitor monitor;
} sd_scope;

typedef struct sd_directory {
    sd_scope *scope;
    int node;
} sd_directory;

static ErlNifResourceType *sd_scope_type;
static ErlNifResourceType *sd_directory_type;
static ErlNifMutex *sd_queue_mutex;
static ErlNifCond *sd_queue_condition;
static ErlNifTid sd_worker;
static sd_control *sd_queue_head;
static sd_control *sd_queue_tail;
static int sd_stopping;
static _Atomic unsigned sd_live_controls;

static ERL_NIF_TERM sd_error(ErlNifEnv *env, const char *literal) {
    return make_error_tuple(env, enif_make_atom(env, literal));
}

static void sd_retain(sd_control *c) {
    atomic_fetch_add(&c->refs, 1);
}

static void sd_release(sd_control *c) {
    if (atomic_fetch_sub(&c->refs, 1) == 1) {
        /* Unexpected undrainable lease preserves controls/exclusion for diagnosis. */
        if (c->lease_quarantined || (c->lease && swarm_lease_active(c->lease))) {
            atomic_store(&c->refs, 1);
            return;
        }
        if (c->lease) swarm_lease_free(c->lease);
        enif_mutex_destroy(c->io_mutex);
        enif_free(c);
        atomic_fetch_sub(&sd_live_controls, 1);
    }
}

/* Caller holds IO mutex. Only dirty IO calls or cleanup thread invoke this. */
static void sd_close_graph(sd_control *c) {
    int failed = c->close_error;
    if (atomic_load(&c->terminal)) return;
    if(c->binding_quarantined){
        c->lease_quarantined=1;atomic_store(&c->terminal,2);return;
    }
    if (c->binding_connections) { atomic_store(&c->queued, 0); return; }
    if (c->binding_vfs) {
        if (swarm_bound_dispose(c->binding_vfs)!=SQLITE_OK) {
            c->binding_quarantined=1; c->lease_quarantined=1;
            atomic_store(&c->terminal,2); return;
        }
        c->binding_vfs=NULL;
    }
    if (c->binding_fd >= 0) {
        int fd = c->binding_fd; c->binding_fd = -1;
        if (close(fd)) {c->binding_quarantined=1;c->lease_quarantined=1;atomic_store(&c->terminal,2);return;}
    }
    if (c->lease) {
        int rc = swarm_lease_close(c->lease);
        if (swarm_lease_active(c->lease)) {
            c->lease_close_failed = 1;
            c->lease_quarantined = 1;
            atomic_store(&c->terminal, 2);
            return; /* Never release directory flocks below a live SQLite child. */
        }
        atomic_store(&c->lease_required, 0);
        if (rc != SQLITE_OK) { c->lease_close_failed = 1; failed = 1; }
    }
    if (c->locked) {
        if (flock(c->nodes[c->data_node].fd, LOCK_UN)) failed = 1;
        if (flock(c->nodes[c->runtime_node].fd, LOCK_UN)) failed = 1;
        c->locked = 0;
    }
    for (int i = c->node_count - 1; i >= 0; i--) {
        int fd = c->nodes[i].fd;
        c->nodes[i].fd = -1;
        /* Do not retry close(EINTR): the descriptor may have been consumed. */
        if (fd >= 0 && close(fd)) failed = 1;
    }
    atomic_store(&c->terminal, failed ? 2 : 1);
}

/* Queue node is intrinsic to c; callback allocates nothing and never takes IO lock. */
static void sd_revoke(sd_control *c) {
    atomic_store(&c->revoked, 1);
    if (atomic_exchange(&c->queued, 1)) return;
    sd_retain(c);
    enif_mutex_lock(sd_queue_mutex);
    c->queue_next = NULL;
    if (sd_queue_tail) sd_queue_tail->queue_next = c;
    else sd_queue_head = c;
    sd_queue_tail = c;
    enif_cond_signal(sd_queue_condition);
    enif_mutex_unlock(sd_queue_mutex);
}

static void *sd_cleanup_main(void *arg) {
    (void)arg;
    for (;;) {
        enif_mutex_lock(sd_queue_mutex);
        while (!sd_queue_head && !sd_stopping)
            enif_cond_wait(sd_queue_condition, sd_queue_mutex);
        if (!sd_queue_head && sd_stopping) {
            enif_mutex_unlock(sd_queue_mutex);
            return NULL;
        }
        sd_control *c = sd_queue_head;
        sd_queue_head = c->queue_next;
        if (!sd_queue_head) sd_queue_tail = NULL;
        enif_mutex_unlock(sd_queue_mutex);
        enif_mutex_lock(c->io_mutex);
        sd_close_graph(c);
        enif_mutex_unlock(c->io_mutex);
        sd_release(c);
    }
}

static void sd_scope_destroy(ErlNifEnv *env, void *value) {
    (void)env;
    sd_scope *scope = value;
    if (scope->control) {
        sd_revoke(scope->control);
        sd_release(scope->control);
    }
}

static void sd_owner_down(ErlNifEnv *env, void *value, ErlNifPid *pid,
                          ErlNifMonitor *monitor) {
    (void)env; (void)pid; (void)monitor;
    sd_scope *scope = value;
    sd_revoke(scope->control);
}

static void sd_directory_destroy(ErlNifEnv *env, void *value) {
    (void)env;
    sd_directory *directory = value;
    if (directory->scope) enif_release_resource(directory->scope);
}

static int sd_same(const struct stat *a, const struct stat *b) {
    return S_ISDIR(a->st_mode) && S_ISDIR(b->st_mode) &&
      a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_uid == b->st_uid;
}

static int sd_private(const struct stat *st) {
    return S_ISDIR(st->st_mode) && st->st_uid == geteuid() &&
      (st->st_mode & 07777) == 0700;
}

/* Bounded UTF-8 validation, including overlong/surrogate/out-of-range refusal. */
static int sd_utf8(const unsigned char *s, size_t n) {
    for (size_t i = 0; i < n;) {
        unsigned code = s[i++];
        unsigned count, minimum;
        if (code < 0x80) { if (!code) return 0; continue; }
        if (code >= 0xc2 && code <= 0xdf) { count = 1; minimum = 0x80; code &= 0x1f; }
        else if (code >= 0xe0 && code <= 0xef) { count = 2; minimum = 0x800; code &= 0xf; }
        else if (code >= 0xf0 && code <= 0xf4) { count = 3; minimum = 0x10000; code &= 7; }
        else return 0;
        if (n - i < count) return 0;
        while (count--) {
            unsigned next = s[i++];
            if ((next & 0xc0) != 0x80) return 0;
            code = (code << 6) | (next & 0x3f);
        }
        if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return 0;
    }
    return 1;
}

static int sd_basename(const unsigned char *name, size_t size) {
    return size > 0 && size <= SD_MAX_NAME && sd_utf8(name, size) &&
      !memchr(name, '/', size) && !(size == 1 && name[0] == '.') &&
      !(size == 2 && name[0] == '.' && name[1] == '.');
}

/* Every operation takes io_mutex; DOWN sets revoked atomically without that lock. */
static const char *sd_admit_caller(ErlNifEnv *env, sd_control *c) {
    ErlNifPid caller;
    if (atomic_load(&c->revoked)) return "directory_scope_revoked";
    if (!enif_self(env, &caller) || enif_compare_pids(&caller, &c->owner))
        return "directory_wrong_owner";
    if (!enif_is_process_alive(env, &c->owner)) {
        sd_revoke(c);
        return "directory_scope_revoked";
    }
    return NULL;
}

/* Revalidate every held descriptor and parent dentry before opening/locking. */
static int sd_validate_graph(sd_control *c) {
    struct stat held, named;
    for (int i = 0; i < c->node_count; i++) {
        sd_node *node = &c->nodes[i];
        if (node->fd < 0 || fstat(node->fd, &held) || !sd_same(&held, &node->identity) ||
            (node->private_leaf && !sd_private(&held))) return 0;
        if (node->parent >= 0 &&
            (fstatat(c->nodes[node->parent].fd, node->name, &named, AT_SYMLINK_NOFOLLOW) ||
             !sd_same(&held, &named))) return 0;
    }
    return 1;
}

static const char *sd_ready(ErlNifEnv *env, sd_control *c) {
    const char *error = sd_admit_caller(env, c);
    if (error) return error;
    if (!sd_validate_graph(c)) {
        sd_revoke(c);
        return "directory_binding_changed";
    }
    return NULL;
}

static int sd_append(sd_control *c, int fd, int parent, const char *name,
                     int private_leaf, const struct stat *st) {
    if (c->node_count == SD_MAX_NODES) return -1;
    int index = c->node_count++;
    sd_node *node = &c->nodes[index];
    node->fd = fd;
    node->parent = parent;
    node->private_leaf = private_leaf;
    node->identity = *st;
    strcpy(node->name, name);
    return index;
}

static ERL_NIF_TERM sd_directory_term(ErlNifEnv *env, sd_scope *scope, int node, int *created) {
    *created = 0;
    sd_directory *directory = enif_alloc_resource(sd_directory_type, sizeof(*directory));
    if (!directory) return sd_error(env, "out_of_memory");
    *created = 1;
    directory->scope = scope;
    directory->node = node;
    enif_keep_resource(scope);
    ERL_NIF_TERM result = enif_make_resource(env, directory);
    enif_release_resource(directory);
    return make_ok_tuple(env, result);
}

static ERL_NIF_TERM sd_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    if (atomic_fetch_add(&sd_live_controls, 1) >= SD_MAX_SCOPES) {
        atomic_fetch_sub(&sd_live_controls, 1);
        return sd_error(env, "directory_capacity");
    }
    sd_control *c = enif_alloc(sizeof(*c));
    sd_scope *scope = enif_alloc_resource(sd_scope_type, sizeof(*scope));
    if (!c || !scope) {
        if (c) enif_free(c);
        if (scope) { scope->control = NULL; enif_release_resource(scope); }
        atomic_fetch_sub(&sd_live_controls, 1);
        return sd_error(env, "out_of_memory");
    }
    memset(c, 0, sizeof(*c));
    memset(scope, 0, sizeof(*scope));
    atomic_init(&c->refs, 1);
    atomic_init(&c->revoked, 0);
    atomic_init(&c->queued, 0);
    atomic_init(&c->terminal, 0);
    atomic_init(&c->lease_required, 0);
    c->runtime_node = c->data_node = -1;
    c->binding_fd = -1;
    c->io_mutex = enif_mutex_create("swarm:directory_scope");
    if (!c->io_mutex || !enif_self(env, &c->owner)) {
        if (c->io_mutex) enif_mutex_destroy(c->io_mutex);
        enif_free(c);
        enif_release_resource(scope);
        atomic_fetch_sub(&sd_live_controls, 1);
        return sd_error(env, "out_of_memory");
    }
    scope->control = c;
    if (enif_monitor_process(env, scope, &c->owner, &scope->monitor)) {
        enif_release_resource(scope);
        return sd_error(env, "directory_scope_revoked");
    }
    ERL_NIF_TERM term = enif_make_resource(env, scope);
    enif_release_resource(scope);
    return make_ok_tuple(env, term);
}

static void sd_discard_fd(sd_control *c, int fd) {
    if (close(fd)) {
        c->close_error = 1;
        sd_revoke(c);
    }
}

/* Failure closes only descriptors appended by this call, all in dirty IO. */
static void sd_rollback_nodes(sd_control *c, int start) {
    while (c->node_count > start) {
        sd_node *node = &c->nodes[--c->node_count];
        sd_discard_fd(c, node->fd);
        node->fd = -1;
    }
}

static ERL_NIF_TERM sd_open_root(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_scope *scope;
    ErlNifBinary path;
    if (argc != 2 || !enif_get_resource(env, argv[0], sd_scope_type, (void **)&scope) ||
        !enif_inspect_binary(env, argv[1], &path)) return enif_make_badarg(env);
    if (path.size < 2 || path.size >= SD_MAX_PATH || path.data[0] != '/' ||
        !sd_utf8(path.data, path.size)) return sd_error(env, "directory_invalid_path");
    char names[SD_MAX_PATH];
    memcpy(names, path.data, path.size);
    names[path.size] = 0;
    for (size_t first = 1, i = 1; i <= path.size; i++) {
        if (i == path.size || names[i] == '/') {
            if (!sd_basename((unsigned char *)names + first, i - first))
                return sd_error(env, "directory_invalid_path");
            first = i + 1;
        }
    }
    sd_control *c = scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *error = sd_ready(env, c);
    int start = c->node_count;
    int parent = -1;
    if (!error && c->node_count == SD_MAX_NODES) error = "directory_capacity";
    if (!error) {
        struct stat st;
        int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) error = "directory_open_failed";
        else if (fstat(fd, &st) || !S_ISDIR(st.st_mode)) {
            sd_discard_fd(c, fd);
            error = "directory_open_failed";
        } else parent = sd_append(c, fd, -1, "", 0, &st);
    }
    for (size_t first = 1, i = 1; !error && i <= path.size; i++) {
        if (i != path.size && names[i] != '/') continue;
        names[i] = 0;
        if (c->node_count == SD_MAX_NODES) { error = "directory_capacity"; break; }
        int fd = openat(c->nodes[parent].fd, names + first,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        struct stat st;
        int final = i == path.size;
        if (fd < 0) error = "directory_open_failed";
        else if (fstat(fd, &st) || !S_ISDIR(st.st_mode) || (final && !sd_private(&st))) {
            sd_discard_fd(c, fd);
            error = "unsafe_private_directory";
        } else parent = sd_append(c, fd, parent, names + first, final, &st);
        first = i + 1;
    }
    if (!error && (!sd_validate_graph(c) || atomic_load(&c->revoked))) {
        sd_revoke(c);
        error = "directory_binding_changed";
    }
    int created = 0;
    ERL_NIF_TERM result = error ? sd_error(env, error) : sd_directory_term(env, scope, parent, &created);
    if (error || !created) sd_rollback_nodes(c, start);
    enif_mutex_unlock(c->io_mutex);
    return result;
}

static ERL_NIF_TERM sd_open_child(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_directory *parent;
    ErlNifBinary name;
    if (argc != 2 || !enif_get_resource(env, argv[0], sd_directory_type, (void **)&parent) ||
        !enif_inspect_binary(env, argv[1], &name)) return enif_make_badarg(env);
    if (!sd_basename(name.data, name.size)) return sd_error(env, "directory_invalid_basename");
    char basename[SD_MAX_NAME + 1];
    memcpy(basename, name.data, name.size); basename[name.size] = 0;
    sd_control *c = parent->scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *error = sd_ready(env, c);
    int start = c->node_count;
    if (!error && start == SD_MAX_NODES) error = "directory_capacity";
    int node = -1;
    if (!error) {
        int fd = openat(c->nodes[parent->node].fd, basename,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        struct stat st;
        if (fd < 0) error = "directory_open_failed";
        else if (fstat(fd, &st) || !sd_private(&st)) {
            sd_discard_fd(c, fd);
            error = "unsafe_private_directory";
        } else node = sd_append(c, fd, parent->node, basename, 1, &st);
    }
    if (!error && (!sd_validate_graph(c) || atomic_load(&c->revoked))) {
        sd_revoke(c); error = "directory_binding_changed";
    }
    int created = 0;
    ERL_NIF_TERM result = error ? sd_error(env, error) : sd_directory_term(env, parent->scope, node, &created);
    if (error || !created) sd_rollback_nodes(c, start);
    enif_mutex_unlock(c->io_mutex);
    return result;
}

static ERL_NIF_TERM sd_identity(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_directory *directory;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_directory_type, (void **)&directory))
        return enif_make_badarg(env);
    sd_control *c = directory->scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *error = sd_ready(env, c);
    const struct stat *st = &c->nodes[directory->node].identity;
    ERL_NIF_TERM result = error ? sd_error(env, error) : make_ok_tuple(env,
      enif_make_tuple5(env, enif_make_atom(env, "directory"),
        enif_make_uint64(env, st->st_dev), enif_make_uint64(env, st->st_ino),
        enif_make_uint64(env, st->st_uid), enif_make_uint(env, st->st_mode & 07777)));
    enif_mutex_unlock(c->io_mutex);
    return result;
}

static ERL_NIF_TERM sd_lock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_scope *scope; sd_directory *runtime, *data;
    if (argc != 3 || !enif_get_resource(env, argv[0], sd_scope_type, (void **)&scope) ||
        !enif_get_resource(env, argv[1], sd_directory_type, (void **)&runtime) ||
        !enif_get_resource(env, argv[2], sd_directory_type, (void **)&data))
        return enif_make_badarg(env);
    if (runtime->scope != scope || data->scope != scope) return sd_error(env, "directory_wrong_scope");
    sd_control *c = scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *error = sd_ready(env, c);
    if (!error && c->locked) error = "directory_already_locked";
    if (!error && sd_same(&c->nodes[runtime->node].identity, &c->nodes[data->node].identity))
        error = "directory_alias";
    if (!error && flock(c->nodes[runtime->node].fd, LOCK_EX | LOCK_NB))
        error = (errno == EWOULDBLOCK || errno == EAGAIN) ? "foundation_lock_held" : "directory_lock_failed";
    if (!error) {
        if (flock(c->nodes[data->node].fd, LOCK_EX | LOCK_NB)) {
            error = (errno == EWOULDBLOCK || errno == EAGAIN) ? "foundation_lock_held" : "directory_lock_failed";
            if (flock(c->nodes[runtime->node].fd, LOCK_UN)) sd_revoke(c);
        } else {
            c->runtime_node = runtime->node; c->data_node = data->node; c->locked = 1;
            if (!sd_validate_graph(c) || atomic_load(&c->revoked)) {
                sd_revoke(c); error = "directory_binding_changed";
            }
        }
    }
    enif_mutex_unlock(c->io_mutex);
    return error ? sd_error(env, error) : am_ok;
}

static ERL_NIF_TERM sd_assert_locked(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_scope *scope;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_scope_type, (void **)&scope))
        return enif_make_badarg(env);
    sd_control *c = scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *error = sd_ready(env, c);
    if (!error && !c->locked) error = "directory_not_locked";
    /* No descriptor escapes and only this owner graph can unlock/close it. */
    enif_mutex_unlock(c->io_mutex);
    return error ? sd_error(env, error) : am_ok;
}

static ERL_NIF_TERM sd_status(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_scope *scope;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_scope_type, (void **)&scope))
        return enif_make_badarg(env);
    int terminal = atomic_load(&scope->control->terminal);
    return enif_make_atom(env, terminal == 2 ? "close_failed" : terminal == 1 ? "closed" :
      atomic_load(&scope->control->revoked) ? "revoked" : "live");
}

static ERL_NIF_TERM sd_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_scope *scope;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_scope_type, (void **)&scope))
        return enif_make_badarg(env);
    sd_control *c = scope->control;
    ErlNifPid caller;
    if (!enif_self(env, &caller) || enif_compare_pids(&caller, &c->owner))
        return sd_error(env, "directory_wrong_owner");
    enif_mutex_lock(c->io_mutex);
    if (c->lease && swarm_lease_active(c->lease) && !atomic_load(&c->revoked)) {
        enif_mutex_unlock(c->io_mutex);
        return sd_error(env, "directory_scope_in_use");
    }
    sd_revoke(c);
    sd_close_graph(c);
    int terminal = atomic_load(&c->terminal);
    enif_mutex_unlock(c->io_mutex);
    return terminal == 1 ? am_ok : sd_error(env, "directory_close_failed");
}

#include "swarm_lease_nif.c"

static int sd_service_load(ErlNifEnv *env) {
    ErlNifResourceTypeInit scope_init = {0};
    ErlNifResourceTypeInit directory_init = {0};
    scope_init.members = 3;
    directory_init.members = 3;
    scope_init.dtor = sd_scope_destroy;
    scope_init.down = sd_owner_down;
    directory_init.dtor = sd_directory_destroy;
    sd_scope_type = enif_open_resource_type_x(env, "swarm_directory_scope", &scope_init,
      ERL_NIF_RT_CREATE, NULL);
    sd_directory_type = enif_open_resource_type_x(env, "swarm_directory", &directory_init,
      ERL_NIF_RT_CREATE, NULL);
    sd_lease_type = enif_open_resource_type(env, NULL, "swarm_guarded_lease",
      sd_lease_destroy, ERL_NIF_RT_CREATE, NULL);
    if (!sd_scope_type || !sd_directory_type || !sd_lease_type) return -1;
    sd_queue_mutex = enif_mutex_create("swarm:directory_cleanup");
    sd_queue_condition = enif_cond_create("swarm:directory_cleanup");
    if (!sd_queue_mutex || !sd_queue_condition) {
        if (sd_queue_mutex) enif_mutex_destroy(sd_queue_mutex);
        if (sd_queue_condition) enif_cond_destroy(sd_queue_condition);
        return -1;
    }
    sd_stopping = 0; sd_queue_head = sd_queue_tail = NULL;
    atomic_init(&sd_live_controls, 0);
    if (enif_thread_create("swarm_directory_cleanup", &sd_worker, sd_cleanup_main, NULL, NULL)) {
        enif_mutex_destroy(sd_queue_mutex);
        enif_cond_destroy(sd_queue_condition);
        return -1;
    }
    return 0;
}

static void sd_service_unload(void) {
    enif_mutex_lock(sd_queue_mutex);
    sd_stopping = 1;
    enif_cond_signal(sd_queue_condition);
    enif_mutex_unlock(sd_queue_mutex);
    enif_thread_join(sd_worker, NULL);
    enif_mutex_destroy(sd_queue_mutex);
    enif_cond_destroy(sd_queue_condition);
}
#endif
