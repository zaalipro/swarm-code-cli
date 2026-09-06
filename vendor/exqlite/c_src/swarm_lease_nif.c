/* Included in the production directory resource translation unit. */
typedef struct sd_lease {
    sd_scope *scope;
} sd_lease;
static ErlNifResourceType *sd_lease_type;

static int sd_lease_validate(void *context) {
    sd_control *c = context;
    /* Called only inside SQLite while the NIF/worker owns the scope IO mutex. */
    return !atomic_load(&c->revoked) && c->locked && sd_validate_graph(c);
}

static void sd_lease_destroy(ErlNifEnv *env, void *value) {
    (void)env;
    sd_lease *lease = value;
    if (lease->scope) {
        /* GC is a lifecycle signal, never a place to execute SQLite or wait on IO. */
        if (atomic_load(&lease->scope->control->lease_required))
            sd_revoke(lease->scope->control);
        enif_release_resource(lease->scope);
    }
}

static ERL_NIF_TERM sd_lease_acquire(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_scope *scope;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_scope_type, (void **)&scope))
        return enif_make_badarg(env);
    sd_control *c = scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *error = sd_ready(env, c);
    if (!error && !c->locked) error = "directory_not_locked";
    if (!error && c->lease_attempted) error = "lease_already_attempted";
    sd_lease *lease = NULL;
    if (!error) {
        lease = enif_alloc_resource(sd_lease_type, sizeof(*lease));
        if (!lease) error = "out_of_memory";
        else lease->scope = NULL;
    }
    if (!error) {
        c->lease_attempted = 1;
#ifdef SWARM_GUARD_TEST
        int rc = swarm_lease_acquire_test(c->nodes[c->data_node].fd, sd_lease_validate, c,
          &c->lease_test_fault, &c->lease);
#else
        int rc = swarm_lease_acquire(c->nodes[c->data_node].fd, sd_lease_validate, c, &c->lease);
#endif
        if (rc != SQLITE_OK || atomic_load(&c->revoked)) {
            error = rc == SQLITE_BUSY || rc == SQLITE_LOCKED ? "lease_held" : "lease_acquisition_failed";
            if (c->lease) {
                int closed = swarm_lease_close(c->lease);
                if (closed != SQLITE_OK) c->lease_close_failed = 1;
            }
            sd_revoke(c);
        }
    }
    ERL_NIF_TERM result;
    if (error) result = sd_error(env, error);
    else {
        atomic_store(&c->lease_required, 1);
        lease->scope = scope;
        enif_keep_resource(scope);
        result = make_ok_tuple(env, enif_make_resource(env, lease));
    }
    enif_mutex_unlock(c->io_mutex);
    if (lease) enif_release_resource(lease);
    return result;
}

static ERL_NIF_TERM sd_lease_assert(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_lease *lease;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_lease_type, (void **)&lease))
        return enif_make_badarg(env);
    sd_control *c = lease->scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *error = sd_ready(env, c);
    if (!error && !swarm_lease_active(c->lease)) error = "lease_closed";
    if (!error && swarm_lease_assert(c->lease) != SQLITE_OK) {
        error = "lease_binding_changed";
        sd_revoke(c);
    }
    enif_mutex_unlock(c->io_mutex);
    return error ? sd_error(env, error) : am_ok;
}

static ERL_NIF_TERM sd_lease_identity(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_lease *lease;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_lease_type, (void **)&lease))
        return enif_make_badarg(env);
    sd_control *c = lease->scope->control;
    struct stat identity;
    enif_mutex_lock(c->io_mutex);
    const char *error = sd_ready(env, c);
    if (!error && !swarm_lease_active(c->lease)) error = "lease_closed";
    if (!error && swarm_lease_identity(c->lease, &identity) != SQLITE_OK) {
        error = "lease_binding_changed";
        sd_revoke(c);
    }
    ERL_NIF_TERM result = error ? sd_error(env, error) : make_ok_tuple(env,
      enif_make_tuple5(env, enif_make_atom(env, "regular"),
        enif_make_uint64(env, identity.st_dev), enif_make_uint64(env, identity.st_ino),
        enif_make_uint64(env, identity.st_uid), enif_make_uint(env, identity.st_mode & 07777)));
    enif_mutex_unlock(c->io_mutex);
    return result;
}

static ERL_NIF_TERM sd_lease_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_lease *lease;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_lease_type, (void **)&lease))
        return enif_make_badarg(env);
    sd_control *c = lease->scope->control;
    ErlNifPid caller;
    if (!enif_self(env, &caller) || enif_compare_pids(&caller, &c->owner))
        return sd_error(env, "directory_wrong_owner");
    enif_mutex_lock(c->io_mutex);
    int rc = swarm_lease_close(c->lease);
    if (!swarm_lease_active(c->lease)) atomic_store(&c->lease_required, 0);
    if (rc != SQLITE_OK) { c->lease_close_failed = 1; sd_revoke(c); }
    enif_mutex_unlock(c->io_mutex);
    return rc == SQLITE_OK ? am_ok : sd_error(env, "lease_close_failed");
}

static ERL_NIF_TERM sd_lease_status(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_lease *lease;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_lease_type, (void **)&lease))
        return enif_make_badarg(env);
    sd_control *c = lease->scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *state = c->lease_close_failed ? "close_failed" :
      !swarm_lease_active(c->lease) ? "closed" : atomic_load(&c->revoked) ? "revoked" : "held";
    enif_mutex_unlock(c->io_mutex);
    return enif_make_atom(env, state);
}

#ifdef SWARM_GUARD_TEST
static ERL_NIF_TERM sd_lease_test_fault(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_scope *scope;
    if (argc != 2 || !enif_get_resource(env, argv[0], sd_scope_type, (void **)&scope))
        return enif_make_badarg(env);
    int site = enif_is_identical(argv[1], enif_make_atom(env, "main_duplicate")) ? 1 :
      enif_is_identical(argv[1], enif_make_atom(env, "journal_duplicate")) ? 2 :
      enif_is_identical(argv[1], enif_make_atom(env, "failed_main_open")) ? 3 : 0;
    if (!site) return enif_make_badarg(env);
    sd_control *c = scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *error = sd_ready(env, c);
    if (!error && (c->lease_test_fault.site || c->lease_test_fault.hits)) error = "fault_already_used";
    if (!error) c->lease_test_fault.site = site;
    enif_mutex_unlock(c->io_mutex);
    return error ? sd_error(env, error) : am_ok;
}

static ERL_NIF_TERM sd_lease_test_hits(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_scope *scope;
    if (argc != 1 || !enif_get_resource(env, argv[0], sd_scope_type, (void **)&scope))
        return enif_make_badarg(env);
    sd_control *c = scope->control;
    enif_mutex_lock(c->io_mutex);
    int hits = c->lease_test_fault.hits;
    enif_mutex_unlock(c->io_mutex);
    return enif_make_int(env, hits);
}
#endif
