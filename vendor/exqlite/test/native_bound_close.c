/* Production VFS close observer; run under ASan/UBSan. The deliberately
 * quarantined binding survives process exit, so leak detection is disabled. */
#define SWARM_GUARD_TEST 1
#include "../c_src/sqlite3.c"
#include "../c_src/swarm_binding_vfs.c"
#undef NDEBUG
#include <assert.h>
#include <stdio.h>
int main(void) {
  char directory[]="/tmp/swarm-bound-close-XXXXXX";
  assert(mkdtemp(directory));
  char path[512];snprintf(path,sizeof(path),"%s/application.db",directory);
  sqlite3 *seed=NULL;
  assert(sqlite3_open(path,&seed)==SQLITE_OK);
  assert(sqlite3_exec(seed,"CREATE TABLE data(id);INSERT INTO data VALUES(1)",NULL,NULL,NULL)==SQLITE_OK);
  assert(sqlite3_close(seed)==SQLITE_OK);assert(chmod(path,0600)==0);
  int parent=open(directory,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
  int mainfd=openat(parent,"application.db",O_RDWR|O_NOFOLLOW|O_CLOEXEC);
  assert(parent>=0&&mainfd>=0);
  assert(swarm_bound_install_close_hook()==SQLITE_OK);
  SbBinding *binding=NULL;
  assert(swarm_bound_admit(parent,mainfd,"application.db",&binding)==SQLITE_OK);
  sqlite3 *first=NULL,*second=NULL,*replacement=NULL;
  assert(swarm_bound_open(binding,&first)==SQLITE_OK);
  assert(swarm_bound_open(binding,&second)==SQLITE_OK);
  assert(sqlite3_exec(first,"BEGIN IMMEDIATE;INSERT INTO data VALUES(2)",NULL,NULL,NULL)==SQLITE_OK);
  assert(swarm_bound_close(binding,second)==SQLITE_OK);
  assert(swarm_bound_open(binding,&replacement)==SQLITE_OK);
  assert(sqlite3_exec(replacement,"INSERT INTO data VALUES(3)",NULL,NULL,NULL)==SQLITE_BUSY);
  assert(sqlite3_exec(first,"COMMIT",NULL,NULL,NULL)==SQLITE_OK);
  assert(sqlite3_exec(replacement,"INSERT INTO data VALUES(3)",NULL,NULL,NULL)==SQLITE_OK);
  assert(swarm_bound_close(binding,replacement)==SQLITE_OK);
  swarm_bound_test_close_fault(binding);
  assert(swarm_bound_close(binding,first)==SQLITE_OK);
  assert(swarm_bound_test_close_hits(binding)==1);
  assert(swarm_bound_close_status(binding)==SQLITE_IOERR_CLOSE);
  assert(swarm_bound_dispose(binding)==SQLITE_IOERR_CLOSE);
  assert(close(mainfd)==0);assert(close(parent)==0);
  assert(unlink(path)==0);assert(rmdir(directory)==0);
  puts("PASS production bound Unix pending-fd bookkeeping and consumed-close quarantine (ASan/UBSan)");
  return 0;
}
