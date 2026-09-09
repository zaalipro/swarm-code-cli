#define SWARM_BINDING_EXPERIMENTAL 1
#include "../c_src/sqlite3_swarm.c"
#include "../c_src/swarm_binding_experimental.c"
#undef NDEBUG
#include <assert.h>
#include <stdio.h>
#include <sys/wait.h>
static void run(sqlite3 *db,const char *sql) {
 char *error=NULL;int rc=sqlite3_exec(db,sql,NULL,NULL,&error);
 if(rc!=SQLITE_OK)fprintf(stderr,"SQL error %d: %s\n",rc,error?error:"unknown");
 sqlite3_free(error);assert(rc==SQLITE_OK);
}
static int count(sqlite3 *db) {
 sqlite3_stmt *s=NULL;assert(sqlite3_prepare_v2(db,"SELECT count(*) FROM records",-1,&s,NULL)==SQLITE_OK);
 assert(sqlite3_step(s)==SQLITE_ROW);int n=sqlite3_column_int(s,0);assert(sqlite3_finalize(s)==SQLITE_OK);return n;
}
typedef struct ThreadWrite { sqlite3 *db; int rc; } ThreadWrite;
static void *write_thread(void *arg) {
 ThreadWrite *w=arg;w->rc=sqlite3_exec(w->db,"BEGIN IMMEDIATE",NULL,NULL,NULL);return NULL;
}
static sqlite3_file *main_file(sqlite3 *db) {
 sqlite3_file *file=NULL;
 assert(sqlite3_file_control(db,"main",SQLITE_FCNTL_FILE_POINTER,&file)==SQLITE_OK);
 return file;
}
int main(void) {
 assert(sqlite3_initialize()==SQLITE_OK);
 char root[]="/tmp/swarm-binding-XXXXXX";assert(mkdtemp(root));
 int parent=open(root,O_RDONLY|O_DIRECTORY|O_CLOEXEC);assert(parent>=0);
 int fd=openat(parent,"application.db",O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);assert(fd>=0);close(fd);
 SbBinding *b=NULL;sqlite3 *db=NULL,*other=NULL;
 assert(sb_admit(parent,&b)==SQLITE_OK);assert(sb_open(b,&db)==SQLITE_OK);
 assert(sb_open(b,&other)==SQLITE_MISUSE&&other==NULL);
 run(db,"PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE records(id INTEGER); INSERT INTO records VALUES(1),(2)");
 assert(count(db)==2);struct stat st;
 assert(fstatat(parent,"application.db-wal",&st,AT_SYMLINK_NOFOLLOW)==0&&st.st_size>0&&(st.st_mode&07777)==0600);
 assert(fstatat(parent,"application.db-shm",&st,AT_SYMLINK_NOFOLLOW)==0&&st.st_size>=32768&&(st.st_mode&07777)==0600);
 assert(sqlite3_exec(db,"ATTACH ':memory:' AS denied",NULL,NULL,NULL)==SQLITE_AUTH);
 assert(sb_close(b,db)==SQLITE_OK);assert(sb_dispose(b)==SQLITE_OK);
 assert(sb_admit(parent,&b)==SQLITE_OK);assert(sb_open(b,&db)==SQLITE_OK);assert(count(db)==2);
 assert(sb_close(b,db)==SQLITE_OK);assert(sb_dispose(b)==SQLITE_OK);
 /* Three pooled handles retain independent reader snapshots and writer locks. */
 assert(sb_admit(parent,&b)==SQLITE_OK);assert(sb_open(b,&db)==SQLITE_OK);
 sqlite3 *reader=NULL,*writer=NULL;
 assert(sb_connect(b,&reader)==SQLITE_OK);assert(sb_connect(b,&writer)==SQLITE_OK);
 assert(sb_dispose(b)==SQLITE_BUSY);
 sqlite3 *capacity[5]={0},*overflow=NULL;
 for(int i=0;i<5;i++)assert(sb_connect(b,&capacity[i])==SQLITE_OK);
 assert(sb_connect(b,&overflow)==SQLITE_BUSY&&overflow==NULL);
 for(int i=0;i<5;i++)assert(sb_close(b,capacity[i])==SQLITE_OK);
 sqlite3_stmt *held=NULL;
 assert(sqlite3_prepare_v2(writer,"SELECT 1",-1,&held,NULL)==SQLITE_OK);
 assert(sb_close(b,writer)==SQLITE_BUSY);assert(sb_dispose(b)==SQLITE_BUSY);
 assert(sqlite3_finalize(held)==SQLITE_OK);
 run(reader,"BEGIN; SELECT * FROM records");
 run(db,"BEGIN IMMEDIATE; INSERT INTO records VALUES(20)");
 ThreadWrite work={writer,SQLITE_OK};pthread_t thread;
 assert(pthread_create(&thread,NULL,write_thread,&work)==0);assert(pthread_join(thread,NULL)==0);
 assert(work.rc==SQLITE_BUSY);
 assert(count(reader)==2);run(db,"COMMIT");assert(count(reader)==2);
 run(reader,"COMMIT");assert(count(reader)==3);assert(count(writer)==3);
 run(db,"DELETE FROM records WHERE id=20");
 /* Two process-local sharers retain one OS lock after either sharer unlocks. */
 sqlite3_file *rf=main_file(reader),*wf=main_file(writer);
 assert(rf->pMethods->xShmLock(rf,7,1,SQLITE_SHM_LOCK|SQLITE_SHM_SHARED)==SQLITE_OK);
 assert(wf->pMethods->xShmLock(wf,7,1,SQLITE_SHM_LOCK|SQLITE_SHM_SHARED)==SQLITE_OK);
 assert(rf->pMethods->xShmLock(rf,7,1,SQLITE_SHM_UNLOCK|SQLITE_SHM_SHARED)==SQLITE_OK);
 assert(sb_close(b,reader)==SQLITE_OK);
 pid_t contender=fork();assert(contender>=0);
 if(contender==0) {
   int shm=openat(parent,"application.db-shm",O_RDWR|O_CLOEXEC);assert(shm>=0);
   struct flock lock={0};lock.l_whence=SEEK_SET;lock.l_start=127;lock.l_len=1;lock.l_type=F_WRLCK;
   assert(fcntl(shm,F_SETLK,&lock)==-1&&(errno==EACCES||errno==EAGAIN));close(shm);_exit(0);
 }
 int contender_status;
 assert(waitpid(contender,&contender_status,0)==contender&&WIFEXITED(contender_status)&&WEXITSTATUS(contender_status)==0);
 assert(wf->pMethods->xShmLock(wf,7,1,SQLITE_SHM_UNLOCK|SQLITE_SHM_SHARED)==SQLITE_OK);
 assert(sb_connect(b,&reader)==SQLITE_OK);assert(count(reader)==2);
 assert(sb_close(b,db)==SQLITE_OK);assert(count(writer)==2);
 sb_revoke(b);assert(sqlite3_exec(writer,"INSERT INTO records VALUES(21)",NULL,NULL,NULL)!=SQLITE_OK);
 assert(sb_connect(b,&db)!=SQLITE_OK&&db==NULL);
 assert(sb_close(b,reader)==SQLITE_OK);assert(sb_close(b,writer)==SQLITE_OK);
 assert(sb_dispose(b)==SQLITE_OK);
 /* A subprocess exits without SQLite close, leaving committed WAL and SHM. */
 pid_t child=fork();assert(child>=0);
 if(child==0) {
   assert(sb_admit(parent,&b)==SQLITE_OK);assert(sb_open(b,&db)==SQLITE_OK);
   run(db,"PRAGMA wal_autocheckpoint=0; INSERT INTO records VALUES(3)");_exit(0);
 }
 int status;assert(waitpid(child,&status,0)==child&&WIFEXITED(status)&&WEXITSTATUS(status)==0);
 assert(fstatat(parent,"application.db-wal",&st,AT_SYMLINK_NOFOLLOW)==0&&st.st_size>0);
 assert(sb_admit(parent,&b)==SQLITE_OK);assert(sb_open(b,&db)==SQLITE_OK);assert(count(db)==3);
 sb_revoke(b);assert(sqlite3_exec(db,"INSERT INTO records VALUES(4)",NULL,NULL,NULL)!=SQLITE_OK);
 assert(sb_close(b,db)==SQLITE_OK);assert(sb_dispose(b)==SQLITE_OK);
 assert(sb_admit(parent,&b)==SQLITE_OK);assert(sb_open(b,&db)==SQLITE_OK);
 assert(count(db)==3);
 run(db,"PRAGMA journal_mode=DELETE; INSERT INTO records VALUES(5)");
 assert(count(db)==4);
 run(db,"PRAGMA journal_mode=WAL; INSERT INTO records VALUES(6)");
 assert(renameat(parent,"application.db-wal",parent,"original.wal")==0);
 fd=openat(parent,"application.db-wal",O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);assert(fd>=0);close(fd);
 assert(sqlite3_exec(db,"INSERT INTO records VALUES(7)",NULL,NULL,NULL)!=SQLITE_OK);
 assert(fstatat(parent,"application.db-wal",&st,AT_SYMLINK_NOFOLLOW)==0&&st.st_size==0);
 assert(sb_close(b,db)==SQLITE_OK);assert(sb_dispose(b)==SQLITE_OK);
 assert(unlinkat(parent,"application.db-wal",0)==0);
 assert(renameat(parent,"original.wal",parent,"application.db-wal")==0);
 assert(sb_admit(parent,&b)==SQLITE_OK);
 assert(renameat(parent,"application.db",parent,"original.db")==0);
 fd=openat(parent,"application.db",O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);assert(fd>=0);close(fd);
 assert(sb_open(b,&db)!=SQLITE_OK&&db==NULL);
 assert(fstatat(parent,"application.db",&st,AT_SYMLINK_NOFOLLOW)==0&&st.st_size==0);
 assert(sb_dispose(b)==SQLITE_OK);
 const char *names[]={"application.db","original.db","application.db-wal","application.db-shm","application.db-journal"};
 for(unsigned i=0;i<sizeof(names)/sizeof(names[0]);i++)unlinkat(parent,names[i],0);
 close(parent);assert(rmdir(root)==0);
 puts("PASS: 3-connection snapshots/replacement, threaded writer busy, 8-connection limit, close-busy, shared OS locks, WAL recovery, rollback, CAS, revoke, replacement refusal");
 return 0;
}
