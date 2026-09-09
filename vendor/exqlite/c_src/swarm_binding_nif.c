/* A pinned application database resource beneath the production scope/lease.
 * The scope owner monitor revokes the entire graph, even with copied resources.
 * There is no SQLite connection opener in this predecessor. */
#if !defined(_WIN32)
typedef struct swarm_binding_resource { sd_lease *lease; _Atomic int closed; } swarm_binding_resource;
static ErlNifResourceType *swarm_binding_type;
typedef struct swarm_binding_ticket {
    swarm_binding_resource *binding;
    ErlNifPid consumer;
    _Atomic int consumed;
} swarm_binding_ticket;
static ErlNifResourceType *swarm_binding_ticket_type;
static void swarm_binding_ticket_dtor(ErlNifEnv *env, void *value) {
    (void)env; swarm_binding_ticket *t=value; enif_release_resource(t->binding);
}
static void swarm_binding_revoke(void *value){sd_revoke(value);}
static int swarm_binding_health(void *value) {
    sd_control *c=value;
    enif_mutex_lock(c->io_mutex);
    int ok=!atomic_load(&c->revoked) && c->locked && sd_validate_graph(c) &&
      c->binding_fd>=0 && swarm_lease_active(c->lease) && swarm_lease_assert(c->lease)==SQLITE_OK;
    if(!ok)sd_revoke(c);
    enif_mutex_unlock(c->io_mutex);
    return ok;
}

static int swarm_binding_private(const struct stat *s) {
    return S_ISREG(s->st_mode) && s->st_uid == geteuid() &&
      s->st_nlink == 1 && (s->st_mode & 07777) == 0600;
}
static int swarm_binding_same(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_uid == b->st_uid;
}
static void swarm_binding_dtor(ErlNifEnv *env, void *value) {
    (void)env;
    swarm_binding_resource *b = value;
    if (b->lease) {
        if (!atomic_load(&b->closed)) sd_revoke(b->lease->scope->control);
        enif_release_resource(b->lease);
    }
}
static int swarm_binding_service_load(ErlNifEnv *env) {
    swarm_binding_type = enif_open_resource_type(env, NULL, "swarm_database_binding",
      swarm_binding_dtor, ERL_NIF_RT_CREATE, NULL);
    swarm_binding_ticket_type=enif_open_resource_type(env,NULL,"swarm_database_ticket",
      swarm_binding_ticket_dtor,ERL_NIF_RT_CREATE,NULL);
    return swarm_binding_type && swarm_binding_ticket_type ? 0 : -1;
}
/* All caller/IO validation occurs under the native scope mutex. */
static const char *swarm_binding_ready(ErlNifEnv *env, sd_control *c) {
    const char *e = sd_ready(env, c);
    if (!e && !c->locked) e = "directory_not_locked";
    if (!e && !swarm_lease_active(c->lease)) e = "lease_closed";
    if (!e && swarm_lease_assert(c->lease) != SQLITE_OK) {
        sd_revoke(c); e = "database_binding_changed";
    }
    return e;
}
static const char *swarm_binding_validate(ErlNifEnv *env, sd_control *c) {
    const char *e = swarm_binding_ready(env, c);
    if (!e && c->binding_fd < 0) e = "database_binding_closed";
    struct stat held, named;
    if (!e && (fstat(c->binding_fd, &held) || !swarm_binding_private(&held) ||
      !swarm_binding_same(&held, &c->binding_identity) ||
      fstatat(c->nodes[c->data_node].fd, c->binding_name, &named, AT_SYMLINK_NOFOLLOW) ||
      !swarm_binding_private(&named) || !swarm_binding_same(&held, &named))) {
        sd_revoke(c); e = "database_binding_changed";
    }
    /* Sidecars belong to the admitted namespace.  Validate every existing
     * entry without following symlinks before a reconnect or assertion. */
    if (!e) {
        char sidecars[3][96];
        snprintf(sidecars[0],96,"%s-wal",c->binding_name);
        snprintf(sidecars[1],96,"%s-shm",c->binding_name);
        snprintf(sidecars[2],96,"%s-journal",c->binding_name);
        for (size_t i = 0; i < sizeof(sidecars) / sizeof(sidecars[0]); i++) {
            struct stat sidecar;
            if (fstatat(c->nodes[c->data_node].fd, sidecars[i], &sidecar,
                        AT_SYMLINK_NOFOLLOW) == 0) {
                if (!swarm_binding_private(&sidecar)) {
                    sd_revoke(c); e = "database_binding_changed"; break;
                }
            } else if (errno != ENOENT) {
                sd_revoke(c); e = "database_binding_changed"; break;
            }
        }
    }
    return e;
}
static ERL_NIF_TERM swarm_binding_acquire(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sd_lease *lease;
    const ERL_NIF_TERM *parts; int arity;
    ErlNifUInt64 device, inode, uid;
    ErlNifBinary name;
    if ((argc != 2 && argc != 3) || !enif_get_resource(env, argv[0], sd_lease_type, (void **)&lease) ||
      !enif_get_tuple(env, argv[1], &arity, &parts) || arity != 3 ||
      !enif_get_uint64(env, parts[0], &device) || !enif_get_uint64(env, parts[1], &inode) ||
      !enif_get_uint64(env, parts[2], &uid)) return enif_make_badarg(env);
    if(argc==3 && (!enif_inspect_binary(env,argv[2],&name) || name.size>=64 || !sd_basename(name.data,name.size)))
      return sd_error(env,"invalid_database_basename");
    sd_control *c = lease->scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *e = swarm_binding_ready(env, c);
    if (!e && c->binding_attempted) e = "database_binding_already_attempted";
    swarm_binding_resource *b = NULL;
    if (!e) {
        c->binding_attempted = 1;
        if(argc==3){memcpy(c->binding_name,name.data,name.size);c->binding_name[name.size]=0;}
        else strcpy(c->binding_name,"application.db");
        c->binding_fd = openat(c->nodes[c->data_node].fd, c->binding_name,
          O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (c->binding_fd < 0 || fstat(c->binding_fd, &c->binding_identity) ||
          !swarm_binding_private(&c->binding_identity) ||
          (ErlNifUInt64)c->binding_identity.st_dev != device ||
          (ErlNifUInt64)c->binding_identity.st_ino != inode ||
          (ErlNifUInt64)c->binding_identity.st_uid != uid) e = "database_binding_changed";
        if (!e) e = swarm_binding_validate(env, c);
        if (!e && swarm_bound_admit(c->nodes[c->data_node].fd,c->binding_fd,c->binding_name,&c->binding_vfs)!=SQLITE_OK)
            e="database_binding_changed";
        if (!e) {
            swarm_bound_health(c->binding_vfs,swarm_binding_health,swarm_binding_revoke,c);
            b = enif_alloc_resource(swarm_binding_type, sizeof(*b));
            if (!b) e = "out_of_memory";
            else { b->lease = lease; atomic_init(&b->closed, 0); enif_keep_resource(lease); }
        }
        if (e) sd_revoke(c);
    }
    ERL_NIF_TERM result = e ? sd_error(env, e) : make_ok_tuple(env, enif_make_resource(env, b));
    enif_mutex_unlock(c->io_mutex);
    if (b) enif_release_resource(b);
    return result;
}

/* Owner-only first creation: authority is the retained data directory fd;
 * callers never provide or receive a pathname. */
static ERL_NIF_TERM swarm_binding_create(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  sd_lease *lease; ErlNifBinary name; swarm_binding_resource *b=NULL;
  if(argc!=2 || !enif_get_resource(env,argv[0],sd_lease_type,(void**)&lease))return enif_make_badarg(env);
  if(!enif_inspect_binary(env,argv[1],&name) || name.size>=64 || !sd_basename(name.data,name.size))
    return sd_error(env,"invalid_database_basename");
  sd_control *c=lease->scope->control; enif_mutex_lock(c->io_mutex);
  const char *e=swarm_binding_ready(env,c);
  if(!e && c->binding_attempted)e="database_binding_already_attempted";
  struct stat st; int fd=-1;
  if(!e){
    c->binding_attempted=1; memcpy(c->binding_name,name.data,name.size);c->binding_name[name.size]=0;
    static const char *suffixes[]={"-wal","-shm","-journal"};
    for(int i=0;i<3&&!e;i++){
      char sidecar[96];snprintf(sidecar,sizeof(sidecar),"%s%s",c->binding_name,suffixes[i]);
      if(fstatat(c->nodes[c->data_node].fd,sidecar,&st,AT_SYMLINK_NOFOLLOW)==0 || errno!=ENOENT)
        e="database_binding_changed";
    }
    if(!e){
      fd=openat(c->nodes[c->data_node].fd,c->binding_name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0600);
      c->binding_fd=fd;
      if(fd<0 || fstat(fd,&st) || !swarm_binding_private(&st) || fsync(c->nodes[c->data_node].fd)) e="database_binding_create_failed";
    }
    if(!e){ c->binding_fd=fd;c->binding_identity=st;
      if(swarm_binding_validate(env,c)!=NULL || swarm_bound_admit(c->nodes[c->data_node].fd,fd,c->binding_name,&c->binding_vfs)!=SQLITE_OK)e="database_binding_changed";
    }
    if(!e){ swarm_bound_health(c->binding_vfs,swarm_binding_health,swarm_binding_revoke,c);b=enif_alloc_resource(swarm_binding_type,sizeof(*b));if(!b)e="out_of_memory";else{b->lease=lease;atomic_init(&b->closed,0);enif_keep_resource(lease);} }
    if(e){if(fd>=0 && c->binding_fd!=fd)close(fd);sd_revoke(c);}
  }
  ERL_NIF_TERM result;
  if(e)result=sd_error(env,e);else { ERL_NIF_TERM id=enif_make_tuple3(env,enif_make_uint64(env,st.st_dev),enif_make_uint64(env,st.st_ino),enif_make_uint64(env,st.st_uid));result=enif_make_tuple3(env,am_ok,enif_make_resource(env,b),id); }
  enif_mutex_unlock(c->io_mutex);if(b)enif_release_resource(b);return result;
}
static ERL_NIF_TERM swarm_binding_assert(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    swarm_binding_resource *b;
    if (argc != 1 || !enif_get_resource(env, argv[0], swarm_binding_type, (void **)&b))
      return enif_make_badarg(env);
    sd_control *c = b->lease->scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *e = swarm_binding_validate(env, c);
    enif_mutex_unlock(c->io_mutex);
    return e ? sd_error(env, e) : am_ok;
}
static ERL_NIF_TERM swarm_binding_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    swarm_binding_resource *b;
    if (argc != 1 || !enif_get_resource(env, argv[0], swarm_binding_type, (void **)&b))
      return enif_make_badarg(env);
    sd_control *c = b->lease->scope->control;
    ErlNifPid caller;
    if (!enif_self(env, &caller) || enif_compare_pids(&caller, &c->owner))
      return sd_error(env, "directory_wrong_owner");
    enif_mutex_lock(c->io_mutex);
    if(c->binding_connections){enif_mutex_unlock(c->io_mutex);return sd_error(env,"database_binding_in_use");}
    if(c->binding_vfs){
        if(swarm_bound_dispose(c->binding_vfs)!=SQLITE_OK){
            c->binding_quarantined=1;c->lease_quarantined=1;sd_revoke(c);
            enif_mutex_unlock(c->io_mutex);return sd_error(env,"database_binding_close_failed");
        }
        c->binding_vfs=NULL;
    }
    int fd = c->binding_fd; c->binding_fd = -1; atomic_store(&b->closed, 1);
    int failed = fd >= 0 && close(fd);
    if (failed) { c->close_error = 1; c->binding_quarantined=1;c->lease_quarantined=1;sd_revoke(c); }
    enif_mutex_unlock(c->io_mutex);
    return failed ? sd_error(env, "database_binding_close_failed") : am_ok;
}
static ERL_NIF_TERM swarm_binding_status(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    swarm_binding_resource *b;
    if (argc != 1 || !enif_get_resource(env, argv[0], swarm_binding_type, (void **)&b))
      return enif_make_badarg(env);
    sd_control *c = b->lease->scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *state = c->binding_quarantined ? "close_failed" : c->binding_fd < 0 ? "closed" : atomic_load(&c->revoked) ? "revoked" : "pinned";
    enif_mutex_unlock(c->io_mutex);
    return enif_make_atom(env, state);
}
static ERL_NIF_TERM swarm_binding_authorize(ErlNifEnv *env,int argc,const ERL_NIF_TERM argv[]) {
    swarm_binding_resource *b;ErlNifPid pid;
    if(argc!=2||!enif_get_resource(env,argv[0],swarm_binding_type,(void**)&b)||!enif_get_local_pid(env,argv[1],&pid))return enif_make_badarg(env);
    sd_control *c=b->lease->scope->control;
    enif_mutex_lock(c->io_mutex);
    const char *e=swarm_binding_validate(env,c);
    if(!e&&!enif_is_process_alive(env,&pid))e="database_binding_consumer_dead";
    swarm_binding_ticket *t=NULL;
    if(!e){t=enif_alloc_resource(swarm_binding_ticket_type,sizeof(*t));if(!t)e="out_of_memory";}
    if(t){t->binding=b;t->consumer=pid;atomic_init(&t->consumed,0);enif_keep_resource(b);}
    ERL_NIF_TERM result=e?sd_error(env,e):make_ok_tuple(env,enif_make_resource(env,t));
    enif_mutex_unlock(c->io_mutex);if(t)enif_release_resource(t);return result;
}
static ERL_NIF_TERM swarm_binding_connections(ErlNifEnv *env,int argc,const ERL_NIF_TERM argv[]) {
    swarm_binding_resource *b;
    if(argc!=1||!enif_get_resource(env,argv[0],swarm_binding_type,(void**)&b))return enif_make_badarg(env);
    sd_control *c=b->lease->scope->control;enif_mutex_lock(c->io_mutex);
    unsigned n=c->binding_connections;enif_mutex_unlock(c->io_mutex);return enif_make_uint(env,n);
}
static void swarm_binding_connection_release(connection_t *conn) {
    swarm_binding_resource *b=conn->binding_resource;if(!b)return;
    sd_control *c=b->lease->scope->control;enif_mutex_lock(c->io_mutex);
    c->binding_connections--;
    if(swarm_bound_close_status(c->binding_vfs)!=SQLITE_OK){c->binding_quarantined=1;c->lease_quarantined=1;sd_revoke(c);}
    if(atomic_load(&c->revoked))sd_revoke(c);
    enif_mutex_unlock(c->io_mutex);conn->binding_resource=NULL;enif_release_resource(b);
}
#ifdef SWARM_GUARD_TEST
static ERL_NIF_TERM swarm_binding_test_close_fault(ErlNifEnv *env,int argc,const ERL_NIF_TERM argv[]){
    swarm_binding_resource *b;
    if(argc!=1||!enif_get_resource(env,argv[0],swarm_binding_type,(void**)&b))return enif_make_badarg(env);
    sd_control *c=b->lease->scope->control;
    if(!c->binding_vfs)return sd_error(env,"database_binding_closed");
    swarm_bound_test_close_fault(c->binding_vfs);return am_ok;
}
static ERL_NIF_TERM swarm_binding_test_close_hits(ErlNifEnv *env,int argc,const ERL_NIF_TERM argv[]){
    swarm_binding_resource *b;
    if(argc!=1||!enif_get_resource(env,argv[0],swarm_binding_type,(void**)&b))return enif_make_badarg(env);
    sd_control *c=b->lease->scope->control;
    return enif_make_int(env,c->binding_vfs?swarm_bound_test_close_hits(c->binding_vfs):0);
}
#endif
#endif
