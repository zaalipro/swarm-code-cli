/* Test/development-only feasibility APIs; absent from production builds. */
#include <stdatomic.h>
static _Atomic int guard_live_admissions;
static _Atomic int guard_live_connections;
static ERL_NIF_TERM guard_error(ErlNifEnv *env, const char *literal) {
    return make_error_tuple(env, enif_make_atom(env, literal));
}

static ERL_NIF_TERM guard_stat_term(ErlNifEnv *env, const struct stat *st) {
    return enif_make_tuple5(env, enif_make_atom(env, "regular"),
      enif_make_uint64(env, st->st_dev), enif_make_uint64(env, st->st_ino),
      enif_make_uint64(env, st->st_uid), enif_make_uint(env, st->st_mode & 07777));
}

static void guard_resource_destructor(ErlNifEnv *env, void *arg) {
    (void)env;
    guard_resource_t *resource = arg;
    if (resource->guard) {
        int rc = swarm_guard_dispose(resource->guard);
        if (rc != SQLITE_BUSY) atomic_fetch_sub(&guard_live_admissions, 1);
    }
    if (resource->mutex) enif_mutex_destroy(resource->mutex);
}

static ERL_NIF_TERM guard_admit_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary path;
    if (argc != 1 || !enif_inspect_binary(env, argv[0], &path) ||
        path.size == 0 || path.size > 4095 || path.data[0] != '/' ||
        memchr(path.data, 0, path.size)) return enif_make_badarg(env);
    char name[4096];
    memcpy(name, path.data, path.size);
    name[path.size] = 0;
    guard_resource_t *resource = enif_alloc_resource(guard_resource_type, sizeof(*resource));
    if (!resource) return make_error_tuple(env, am_out_of_memory);
    memset(resource, 0, sizeof(*resource));
    resource->mutex = enif_mutex_create("scratch:guard");
    if (!resource->mutex) {
        enif_release_resource(resource);
        return make_error_tuple(env, am_failed_to_create_mutex);
    }
    int rc = swarm_guard_admit(name, &resource->guard);
    if (rc != SQLITE_OK) {
        enif_release_resource(resource);
        return guard_error(env, "guard_admission_failed");
    }
    atomic_fetch_add(&guard_live_admissions, 1);
    ERL_NIF_TERM term = enif_make_resource(env, resource);
    enif_release_resource(resource);
    return make_ok_tuple(env, term);
}

static ERL_NIF_TERM guard_resource_identity_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    guard_resource_t *resource;
    struct stat identity;
    if (argc != 1 || !enif_get_resource(env, argv[0], guard_resource_type, (void **)&resource))
        return enif_make_badarg(env);
    enif_mutex_lock(resource->mutex);
    ERL_NIF_TERM result;
    if (!resource->guard) result = guard_error(env, "guard_closed");
    else if (swarm_guard_identity(resource->guard, &identity) != SQLITE_OK)
        result = guard_error(env, "guard_identity_failed");
    else result = make_ok_tuple(env, guard_stat_term(env, &identity));
    enif_mutex_unlock(resource->mutex);
    return result;
}

static ERL_NIF_TERM guard_resource_close_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    guard_resource_t *resource;
    if (argc != 1 || !enif_get_resource(env, argv[0], guard_resource_type, (void **)&resource))
        return enif_make_badarg(env);
    enif_mutex_lock(resource->mutex);
    ERL_NIF_TERM result;
    if (!resource->guard) result = guard_error(env, "guard_closed");
    else if (resource->connection_live) result = guard_error(env, "guard_in_use");
    else {
        int rc = swarm_guard_dispose(resource->guard);
        if (rc != SQLITE_BUSY) {
            resource->guard = NULL;
            atomic_fetch_sub(&guard_live_admissions, 1);
        }
        result = rc == SQLITE_OK ? am_ok : guard_error(env,
          rc == SQLITE_BUSY ? "guard_in_use" : "guard_close_failed");
    }
    enif_mutex_unlock(resource->mutex);
    return result;
}

/* Caller holds connection mutex and SQLite has actually finished closing. */
static void guard_connection_release(connection_t *conn) {
    guard_resource_t *resource = conn->guard_resource;
    if (!resource) return;
    enif_mutex_lock(resource->mutex);
    resource->close_attested = swarm_guard_connection_done(resource->guard) == SQLITE_OK;
    resource->connection_live = 0;
    atomic_fetch_sub(&guard_live_connections, 1);
    enif_mutex_unlock(resource->mutex);
    conn->binding_resource = NULL;
    conn->guard_resource = NULL;
    enif_release_resource(resource);
}

static ERL_NIF_TERM guard_open_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    guard_resource_t *resource;
    if (argc != 1 || !enif_get_resource(env, argv[0], guard_resource_type, (void **)&resource))
        return enif_make_badarg(env);
    enif_mutex_lock(resource->mutex);
    if (!resource->guard || resource->consumed) {
        ERL_NIF_TERM result = guard_error(env, resource->guard ? "guard_consumed" : "guard_closed");
        enif_mutex_unlock(resource->mutex);
        return result;
    }
    resource->consumed = 1;
    sqlite3 *db = NULL;
    int rc = swarm_guard_open(resource->guard, &db);
    if (rc != SQLITE_OK) {
        enif_mutex_unlock(resource->mutex);
        return guard_error(env, "guard_open_failed");
    }
    connection_t *conn = enif_alloc_resource(connection_type, sizeof(*conn));
    if (!conn) {
        sqlite3_close(db);
        swarm_guard_connection_done(resource->guard);
        enif_mutex_unlock(resource->mutex);
        return make_error_tuple(env, am_out_of_memory);
    }
    memset(conn, 0, sizeof(*conn));
    conn->db = db;
    conn->mutex = enif_mutex_create("exqlite:connection");
    conn->interrupt_mutex = enif_mutex_create("exqlite:interrupt");
    conn->binding_resource = NULL;
    conn->guard_resource = resource;
    enif_keep_resource(resource);
    resource->connection_live = 1;
    atomic_fetch_add(&guard_live_connections, 1);
    enif_mutex_unlock(resource->mutex);
    if (!conn->mutex || !conn->interrupt_mutex) {
        enif_release_resource(conn);
        return make_error_tuple(env, am_failed_to_create_mutex);
    }
    conn->busy_timeout_ms = 2000;
    conn->progress_handler_steps = 1000;
    sqlite3_busy_handler(db, exqlite_busy_handler, conn);
    connection_configure_progress_handler(conn);
    ERL_NIF_TERM term = enif_make_resource(env, conn);
    enif_release_resource(conn);
    return make_ok_tuple(env, term);
}

static ERL_NIF_TERM guard_connection_identity_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    connection_t *conn;
    struct stat identity;
    if (argc != 1 || !enif_get_resource(env, argv[0], connection_type, (void **)&conn))
        return enif_make_badarg(env);
    connection_acquire_lock(conn);
    ERL_NIF_TERM result;
    if (!conn->db) result = make_error_tuple(env, am_connection_closed);
    else if (!conn->guard_resource || swarm_guard_connection_identity(conn->db, &identity) != SQLITE_OK)
        result = guard_error(env, "guard_identity_failed");
    else result = make_ok_tuple(env, guard_stat_term(env, &identity));
    connection_release_lock(conn);
    return result;
}

static ERL_NIF_TERM guard_close_attested_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    guard_resource_t *resource;
    if (argc != 1 || !enif_get_resource(env, argv[0], guard_resource_type, (void **)&resource))
        return enif_make_badarg(env);
    enif_mutex_lock(resource->mutex);
    int attested = resource->close_attested;
    enif_mutex_unlock(resource->mutex);
    return enif_make_atom(env, attested ? "true" : "false");
}

static ERL_NIF_TERM guard_counts_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    return enif_make_tuple3(env,
      enif_make_int(env, atomic_load(&guard_live_admissions)),
      enif_make_int(env, atomic_load(&guard_live_connections)),
      enif_make_int(env, swarm_guard_registration_count()));
}
