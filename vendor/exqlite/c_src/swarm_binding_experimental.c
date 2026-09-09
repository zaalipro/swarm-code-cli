/* Private bounded multi-connection writable predecessor, not linked into the NIF.
 * Include after the pinned sqlite3.c in a standalone test translation unit.
 * No production admission, lease authority, pools, or BEAM ownership is claimed.
 * Directory flock excludes other instances of this experiment only. */
#ifndef SWARM_BINDING_EXPERIMENTAL
#error This experimental VFS must not be linked into production
#endif
#include <stdatomic.h>
#include <sys/file.h>
#define SB_NAME "/swarm-binding"
#define SB_REGIONS 32
#define SB_REGION_BYTES 32768

typedef struct SbRole { int fd, files; struct stat identity; } SbRole;
typedef struct SbFile SbFile;
typedef struct SbBinding {
  sqlite3_vfs vfs;
  sqlite3_mutex *mutex;
  SbFile *main_files[8];
  sqlite3_io_methods methods;
  int parent, active, shm_fd;
  _Atomic int consumed;
  _Atomic unsigned connections;
  _Atomic int revoked;
  struct stat parent_identity;
  SbRole roles[4];
  void *regions[SB_REGIONS];
  char name[64];
} SbBinding;
struct SbFile { unixFile unix_file; SbBinding *binding; int role; unsigned shared, exclusive; };
static const char *sb_names[] = {"application.db", "application.db-journal", "application.db-wal", "application.db-shm"};
static int sb_private(const struct stat *s) {
  return S_ISREG(s->st_mode) && s->st_uid == geteuid() && s->st_nlink == 1 && (s->st_mode & 07777) == 0600;
}
static int sb_same(const struct stat *a, const struct stat *b) {
  return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_uid == b->st_uid;
}
static int sb_valid(SbBinding *b) {
  struct stat st, held;
  if (atomic_load(&b->revoked) || fstat(b->parent, &st) || !sb_same(&st, &b->parent_identity) ||
      !S_ISDIR(st.st_mode) || (st.st_mode & 07777) != 0700) return 0;
  for (int i=0; i<4; i++) {
    SbRole *r = &b->roles[i];
    if (r->fd < 0) {
      if (fstatat(b->parent, sb_names[i], &st, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) goto changed;
    } else if (fstat(r->fd, &held) || !sb_private(&held) || !sb_same(&held, &r->identity) ||
               fstatat(b->parent, sb_names[i], &st, AT_SYMLINK_NOFOLLOW) || !sb_private(&st) || !sb_same(&held, &st)) goto changed;
  }
  return 1;
changed:
  atomic_store(&b->revoked, 1);
  return 0;
}
static int sb_role(const char *path) {
  if (!path) return -1;
  if (!strcmp(path, SB_NAME)) return 0;
  if (!strcmp(path, SB_NAME "-journal")) return 1;
  if (!strcmp(path, SB_NAME "-wal")) return 2;
  if (!strcmp(path, SB_NAME "-shm")) return 3;
  return -1;
}
static int sb_create(SbBinding *b, int role) {
  SbRole *r=&b->roles[role];
  if (r->fd >= 0) return SQLITE_OK;
  int fd=openat(b->parent,sb_names[role],O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0600);
  if(fd<0) return SQLITE_CANTOPEN;
  r->fd=fd;
  if(fstat(fd,&r->identity)||!sb_private(&r->identity)||fsync(b->parent)) return SQLITE_IOERR;
  return sb_valid(b)?SQLITE_OK:SQLITE_IOERR;
}
static int sb_read_inner(sqlite3_file *f,void *out,int n,sqlite3_int64 at) {
  return sb_valid(((SbFile*)f)->binding)?unixRead(f,out,n,at):SQLITE_IOERR_READ;
}
static int sb_write_inner(sqlite3_file *f,const void *in,int n,sqlite3_int64 at) {
  return sb_valid(((SbFile*)f)->binding)?unixWrite(f,in,n,at):SQLITE_IOERR_WRITE;
}
static int sb_truncate_inner(sqlite3_file *f,sqlite3_int64 n) {
  return sb_valid(((SbFile*)f)->binding)?unixTruncate(f,n):SQLITE_IOERR_TRUNCATE;
}
static int sb_sync_inner(sqlite3_file *f,int flags) {
  SbBinding *b=((SbFile*)f)->binding;
  if(!sb_valid(b)) return SQLITE_IOERR_FSYNC;
  int rc=unixSync(f,flags);
  return rc==SQLITE_OK && fsync(b->parent)?SQLITE_IOERR_DIR_FSYNC:rc;
}
static int sb_size_inner(sqlite3_file *f,sqlite3_int64 *n) {
  return sb_valid(((SbFile*)f)->binding)?unixFileSize(f,n):SQLITE_IOERR_FSTAT;
}
static int sb_lock_inner(sqlite3_file *f,int lock) {
  return sb_valid(((SbFile*)f)->binding)?unixLock(f,lock):SQLITE_IOERR_LOCK;
}
static int sb_control_inner(sqlite3_file *f,int op,void *arg) {
  if(!sb_valid(((SbFile*)f)->binding)) return SQLITE_IOERR;
  if(op==SQLITE_FCNTL_HAS_MOVED){*(int*)arg=0;return SQLITE_OK;}
  if(op==SQLITE_FCNTL_VFSNAME || op==SQLITE_FCNTL_VFS_POINTER || op==SQLITE_FCNTL_TEMPFILENAME) return SQLITE_NOTFOUND;
  return unixFileControl(f,op,arg);
}
static int sb_shm_map_inner(sqlite3_file *f,int page,int size,int extend,void volatile **out) {
  SbBinding *b=((SbFile*)f)->binding;
  *out=NULL;
  if(!sb_valid(b)||page<0||page>=SB_REGIONS||size!=SB_REGION_BYTES) return SQLITE_IOERR_SHMMAP;
  if(b->shm_fd<0) {
    if(sb_create(b,3)!=SQLITE_OK) return SQLITE_IOERR_SHMOPEN;
    b->shm_fd=b->roles[3].fd;
    /* SQLite's Unix dead-man-switch byte. Exclusive acquisition means no live
     * mapper: discard a stale WAL index before taking the shared lifetime lock. */
    struct flock lock={0}; lock.l_whence=SEEK_SET;lock.l_start=128;lock.l_len=1;lock.l_type=F_WRLCK;
    if(fcntl(b->shm_fd,F_SETLK,&lock)==0) {
      if(ftruncate(b->shm_fd,0)) return SQLITE_IOERR_SHMSIZE;
    } else if(errno!=EACCES && errno!=EAGAIN) return SQLITE_IOERR_SHMLOCK;
    lock.l_type=F_RDLCK;
    if(fcntl(b->shm_fd,F_SETLK,&lock)) return SQLITE_IOERR_SHMLOCK;
  }
  if(!b->regions[page]) {
    struct stat st;
    off_t needed=(off_t)(page+1)*size;
    if(fstat(b->shm_fd,&st)) return SQLITE_IOERR_SHMSIZE;
    if(st.st_size<needed) {
      if(!extend) return SQLITE_OK;
      if(ftruncate(b->shm_fd,needed)) return SQLITE_IOERR_SHMSIZE;
    }
    void *p=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_SHARED,b->shm_fd,(off_t)page*size);
    if(p==MAP_FAILED) return SQLITE_IOERR_SHMMAP;
    b->regions[page]=p;
  }
  *out=b->regions[page];return SQLITE_OK;
}
static unsigned sb_shm_aggregate(SbBinding *b, SbFile *except, int exclusive) {
  unsigned mask=0;
  for(int i=0;i<8;i++) if(b->main_files[i] && b->main_files[i]!=except)
    mask |= exclusive ? b->main_files[i]->exclusive : b->main_files[i]->shared;
  return mask;
}
static int sb_shm_lock_inner(sqlite3_file *file,int offset,int n,int flags) {
  SbFile *f=(SbFile*)file;SbBinding *b=f->binding;
  if((flags&SQLITE_SHM_LOCK)&&!sb_valid(b)) return SQLITE_IOERR_SHMLOCK;
  if(b->shm_fd<0||offset<0||n<1||offset+n>SQLITE_SHM_NLOCK) return SQLITE_IOERR_SHMLOCK;
  unsigned mask=((1u<<n)-1)<<offset;
  unsigned others_s=sb_shm_aggregate(b,f,0),others_x=sb_shm_aggregate(b,f,1);
  unsigned next_s=f->shared,next_x=f->exclusive;
  if(flags&SQLITE_SHM_UNLOCK){next_s &= ~mask;next_x &= ~mask;}
  else if(flags&SQLITE_SHM_EXCLUSIVE){
    if((others_s|others_x)&mask)return SQLITE_BUSY;
    next_x |= mask;
  } else {
    if(others_x&mask)return SQLITE_BUSY;
    next_s |= mask;
  }
  for(int i=offset;i<offset+n;i++) {
    unsigned bit=1u<<i;
    short old=(others_x|f->exclusive)&bit?F_WRLCK:(others_s|f->shared)&bit?F_RDLCK:F_UNLCK;
    short next=(others_x|next_x)&bit?F_WRLCK:(others_s|next_s)&bit?F_RDLCK:F_UNLCK;
    if(old==next)continue;
    struct flock lock={0};lock.l_whence=SEEK_SET;lock.l_start=120+i;lock.l_len=1;lock.l_type=next;
    if(fcntl(b->shm_fd,F_SETLK,&lock)) {
      int error=errno;
      for(int j=offset;j<i;j++) {
        bit=1u<<j;lock.l_start=120+j;
        lock.l_type=(others_x|f->exclusive)&bit?F_WRLCK:(others_s|f->shared)&bit?F_RDLCK:F_UNLCK;
        if(fcntl(b->shm_fd,F_SETLK,&lock))atomic_store(&b->revoked,1);
      }
      return error==EACCES||error==EAGAIN?SQLITE_BUSY:SQLITE_IOERR_SHMLOCK;
    }
  }
  f->shared=next_s;f->exclusive=next_x;
  return SQLITE_OK;
}
static void sb_shm_barrier(sqlite3_file *f){(void)f;atomic_thread_fence(memory_order_seq_cst);}
static int sb_shm_unmap_inner(sqlite3_file *f,int remove) {
  SbFile *file=(SbFile*)f;(void)remove;
  if(!file->shared&&!file->exclusive)return SQLITE_OK;
  return sb_shm_lock_inner(f,0,SQLITE_SHM_NLOCK,SQLITE_SHM_UNLOCK|SQLITE_SHM_EXCLUSIVE);
}
static int sb_file_close_inner(sqlite3_file *file) {
  SbFile *f=(SbFile*)file;SbBinding *b=f->binding;int role=f->role;
  int rc=sb_shm_unmap_inner(file,0);
  int closed=unixClose(file);
  if(rc==SQLITE_OK)rc=closed;
  b->roles[role].files--;
  if(role==0){b->active--;for(int i=0;i<8;i++)if(b->main_files[i]==f)b->main_files[i]=NULL;}
  return rc;
}
static int sb_vfs_open_inner(sqlite3_vfs *vfs,const char *path,sqlite3_file *file,int flags,int *out_flags) {
  SbBinding *b=(SbBinding*)vfs;SbFile *f=(SbFile*)file;unixFile *p=&f->unix_file;
  int role=sb_role(path), type=flags&0x0fff00;
  memset(f,0,sizeof(*f));p->h=-1;
  if(!sb_valid(b)||role<0||role==3||(role==0&&b->active>=8)||
      (flags&(SQLITE_OPEN_URI|SQLITE_OPEN_DELETEONCLOSE|SQLITE_OPEN_AUTOPROXY))||
      !(flags&SQLITE_OPEN_READWRITE)||
      (role==0?type!=SQLITE_OPEN_MAIN_DB:role==1?type!=SQLITE_OPEN_MAIN_JOURNAL:type!=SQLITE_OPEN_WAL)) return SQLITE_CANTOPEN;
  if(b->roles[role].fd<0 && (!(flags&SQLITE_OPEN_CREATE)||sb_create(b,role)!=SQLITE_OK)) return SQLITE_CANTOPEN;
  if(role==0) {
    p->pPreallocatedUnused=sqlite3_malloc64(sizeof(UnixUnusedFd));
    if(!p->pPreallocatedUnused)return SQLITE_NOMEM;
    memset(p->pPreallocatedUnused,0,sizeof(UnixUnusedFd));
  }
  int fd=fcntl(b->roles[role].fd,F_DUPFD_CLOEXEC,3);
  if(fd<0){sqlite3_free(p->pPreallocatedUnused);p->pPreallocatedUnused=NULL;return SQLITE_CANTOPEN;}
  if(p->pPreallocatedUnused){p->pPreallocatedUnused->fd=fd;p->pPreallocatedUnused->flags=SQLITE_OPEN_READWRITE;}
#if SQLITE_ENABLE_LOCKING_STYLE
  p->openFlags=O_RDWR|O_NOFOLLOW|O_LARGEFILE|O_BINARY;
#endif
#if defined(__APPLE__) || SQLITE_ENABLE_LOCKING_STYLE
  struct statfs fs;
  if(fstatfs(fd,&fs)||!strncmp("msdos",fs.f_fstypename,5)||!strncmp("exfat",fs.f_fstypename,5)) {
    close(fd);sqlite3_free(p->pPreallocatedUnused);p->pPreallocatedUnused=NULL;return SQLITE_CANTOPEN;
  }
#endif
  /* Match the pinned Unix initialization surrounding fillInUnixFile: owned
   * unused-fd record, filesystem flags, inode discovery and close bookkeeping.
   * NOLOCK avoids stock pathname admission; attach POSIX inode state explicitly. */
  int rc=fillInUnixFile(vfs,fd,file,path,UNIXFILE_NOLOCK);
  if(rc!=SQLITE_OK){sqlite3_free(p->pPreallocatedUnused);p->pPreallocatedUnused=NULL;return rc;}
  {
    unixEnterMutex();rc=findInodeInfo(p,&p->pInode);unixLeaveMutex();
    if(rc!=SQLITE_OK){closeUnixFile(file);return rc;}
    if(role==0) p->ctrlFlags &= ~UNIXFILE_NOLOCK;
  }
#if SQLITE_MAX_MMAP_SIZE > 0
  p->mmapSizeMax=0;
#endif
  f->binding=b;f->role=role;p->pMethod=&b->methods;
  b->roles[role].files++;
  if(role==0){b->active++;for(int i=0;i<8;i++)if(!b->main_files[i]){b->main_files[i]=f;break;}}
  if(out_flags)*out_flags=flags;
  return SQLITE_OK;
}
static int sb_access_inner(sqlite3_vfs *vfs,const char *path,int flags,int *out) {
  SbBinding *b=(SbBinding*)vfs;int role=sb_role(path);(void)flags;
  if(role<0||!sb_valid(b))return SQLITE_IOERR_ACCESS;
  *out=b->roles[role].fd>=0;return SQLITE_OK;
}
static int sb_delete_inner(sqlite3_vfs *vfs,const char *path,int sync) {
  SbBinding *b=(SbBinding*)vfs;int role=sb_role(path);
  if(role<1||role==3||!sb_valid(b)||b->roles[role].files)return SQLITE_IOERR_DELETE;
  if(b->roles[role].fd<0)return SQLITE_OK;
  if(unlinkat(b->parent,sb_names[role],0))return SQLITE_IOERR_DELETE;
  int fd=b->roles[role].fd;b->roles[role].fd=-1;
  if(close(fd))return SQLITE_IOERR_CLOSE;
  return sync&&fsync(b->parent)?SQLITE_IOERR_DIR_FSYNC:SQLITE_OK;
}
static int sb_full_path(sqlite3_vfs *vfs,const char *path,int size,char *out) {
  (void)vfs;if(strcmp(path,SB_NAME)||size<=(int)strlen(SB_NAME))return SQLITE_CANTOPEN;
  sqlite3_snprintf(size,out,"%s",SB_NAME);return SQLITE_OK;
}
/* Serialize binding metadata and per-process SHM lock accounting across DB mutexes. */
static int sb_read(sqlite3_file *f,void *out,int n,sqlite3_int64 at) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_read_inner(f,out,n,at);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_write(sqlite3_file *f,const void *in,int n,sqlite3_int64 at) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_write_inner(f,in,n,at);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_truncate(sqlite3_file *f,sqlite3_int64 n) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_truncate_inner(f,n);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_sync(sqlite3_file *f,int flags) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_sync_inner(f,flags);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_size(sqlite3_file *f,sqlite3_int64 *n) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_size_inner(f,n);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_lock(sqlite3_file *f,int lock) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_lock_inner(f,lock);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_control(sqlite3_file *f,int op,void *arg) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_control_inner(f,op,arg);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_shm_map(sqlite3_file *f,int page,int size,int extend,void volatile **out) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_shm_map_inner(f,page,size,extend,out);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_shm_lock(sqlite3_file *f,int offset,int n,int flags) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_shm_lock_inner(f,offset,n,flags);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_shm_unmap(sqlite3_file *f,int remove) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_shm_unmap_inner(f,remove);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_file_close(sqlite3_file *f) {
  SbBinding *b=((SbFile*)f)->binding;sqlite3_mutex_enter(b->mutex);
  int rc=sb_file_close_inner(f);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_vfs_open(sqlite3_vfs *vfs,const char *path,sqlite3_file *f,int flags,int *out) {
  SbBinding *b=(SbBinding*)vfs;sqlite3_mutex_enter(b->mutex);
  int rc=sb_vfs_open_inner(vfs,path,f,flags,out);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_access(sqlite3_vfs *vfs,const char *path,int flags,int *out) {
  SbBinding *b=(SbBinding*)vfs;sqlite3_mutex_enter(b->mutex);
  int rc=sb_access_inner(vfs,path,flags,out);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_delete(sqlite3_vfs *vfs,const char *path,int sync) {
  SbBinding *b=(SbBinding*)vfs;sqlite3_mutex_enter(b->mutex);
  int rc=sb_delete_inner(vfs,path,sync);sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_authorize(void *ctx,int op,const char *a,const char *b,const char *c,const char *d) {
  (void)ctx;(void)a;(void)b;(void)c;(void)d;
  return op==SQLITE_ATTACH||op==SQLITE_DETACH?SQLITE_DENY:SQLITE_OK;
}
static int sb_dispose(SbBinding *b) {
  if(b->active||atomic_load(&b->connections))return SQLITE_BUSY;
  for(int i=0;i<4;i++)if(b->roles[i].files)return SQLITE_BUSY;
  int rc=SQLITE_OK;
  for(int i=0;i<SB_REGIONS;i++)if(b->regions[i]&&munmap(b->regions[i],SB_REGION_BYTES))rc=SQLITE_IOERR_SHMMAP;
  for(int i=0;i<4;i++)if(b->roles[i].fd>=0&&close(b->roles[i].fd))rc=SQLITE_IOERR_CLOSE;
  if(close(b->parent))rc=SQLITE_IOERR_CLOSE;
  sqlite3_mutex_free(b->mutex);sqlite3_free(b);return rc;
}
static int sb_admit(int parent,SbBinding **out) {
  *out=NULL;SbBinding *b=sqlite3_malloc64(sizeof(*b));if(!b)return SQLITE_NOMEM;
  memset(b,0,sizeof(*b));b->parent=-1;b->shm_fd=-1;atomic_init(&b->revoked,0);atomic_init(&b->consumed,0);atomic_init(&b->connections,0);
  for(int i=0;i<4;i++)b->roles[i].fd=-1;
  b->mutex=sqlite3_mutex_alloc(SQLITE_MUTEX_RECURSIVE);if(!b->mutex)goto bad;
  b->parent=openat(parent,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
  if(b->parent<0||fstat(b->parent,&b->parent_identity)||b->parent_identity.st_uid!=geteuid()||
     (b->parent_identity.st_mode&07777)!=0700||flock(b->parent,LOCK_EX|LOCK_NB))goto bad;
  for(int i=0;i<4;i++) {
    struct stat named;
    if(fstatat(b->parent,sb_names[i],&named,AT_SYMLINK_NOFOLLOW)) {
      if(i>0&&errno==ENOENT)continue;
      goto bad;
    }
    if(!sb_private(&named))goto bad;
    b->roles[i].fd=openat(b->parent,sb_names[i],O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(b->roles[i].fd<0||fstat(b->roles[i].fd,&b->roles[i].identity)||!sb_same(&named,&b->roles[i].identity))goto bad;
  }
  if(!sb_valid(b))goto bad;
  b->vfs=*sqlite3_vfs_find("unix");b->vfs.pNext=NULL;b->vfs.szOsFile=sizeof(SbFile);b->vfs.pAppData=(void*)&posixIoFinder;
  b->vfs.xOpen=sb_vfs_open;b->vfs.xAccess=sb_access;b->vfs.xDelete=sb_delete;b->vfs.xFullPathname=sb_full_path;
  b->methods=posixIoMethods;b->methods.iVersion=2;
  b->methods.xClose=sb_file_close;b->methods.xRead=sb_read;b->methods.xWrite=sb_write;b->methods.xTruncate=sb_truncate;
  b->methods.xSync=sb_sync;b->methods.xFileSize=sb_size;b->methods.xLock=sb_lock;b->methods.xFileControl=sb_control;
  b->methods.xShmMap=sb_shm_map;b->methods.xShmLock=sb_shm_lock;b->methods.xShmBarrier=sb_shm_barrier;b->methods.xShmUnmap=sb_shm_unmap;
  sqlite3_snprintf(sizeof(b->name),b->name,"sb-%p",(void*)b);b->vfs.zName=b->name;*out=b;return SQLITE_OK;
bad:
  sb_dispose(b);return SQLITE_CANTOPEN;
}
static int sb_open_connection_inner(SbBinding *b,sqlite3 **db) {
  *db=NULL;unsigned current=atomic_load(&b->connections);
  while(current<8 && !atomic_compare_exchange_weak(&b->connections,&current,current+1)) {}
  if(current>=8)return SQLITE_BUSY;
  if(!sb_valid(b)){atomic_fetch_sub(&b->connections,1);return SQLITE_CANTOPEN;}
  int rc=sqlite3_vfs_register(&b->vfs,0);if(rc!=SQLITE_OK){atomic_fetch_sub(&b->connections,1);return rc;}
  rc=sqlite3_open_v2(SB_NAME,db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_PRIVATECACHE,b->name);
  sqlite3_vfs_unregister(&b->vfs);
  if(rc==SQLITE_OK)rc=sqlite3_set_authorizer(*db,sb_authorize,b);
  if(rc==SQLITE_OK)rc=sqlite3_exec(*db,"PRAGMA temp_store=MEMORY",NULL,NULL,NULL);
  if(rc!=SQLITE_OK){sqlite3_close(*db);*db=NULL;atomic_fetch_sub(&b->connections,1);}
  return rc;
}
static int sb_open_connection(SbBinding *b,sqlite3 **db) {
  sqlite3_mutex_enter(b->mutex);int rc=sb_open_connection_inner(b,db);
  sqlite3_mutex_leave(b->mutex);return rc;
}
static int sb_connect(SbBinding *b,sqlite3 **db){
  *db=NULL;
  if(!atomic_load(&b->consumed))return SQLITE_MISUSE;
  return sb_open_connection(b,db);
}
static int sb_open(SbBinding *b,sqlite3 **db) {
  *db=NULL;
  int expected=0;
  if(!atomic_compare_exchange_strong(&b->consumed,&expected,1)) return SQLITE_MISUSE;
  return sb_open_connection(b,db);
}
static void sb_revoke(SbBinding *b){atomic_store(&b->revoked,1);}
static int sb_close(SbBinding *b,sqlite3 *db){int rc=sqlite3_close(db);if(rc==SQLITE_OK)atomic_fetch_sub(&b->connections,1);return rc;}
