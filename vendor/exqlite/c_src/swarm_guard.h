#ifndef SWARM_GUARD_H
#define SWARM_GUARD_H
#include <sys/stat.h>
int swarm_guard_registration_count(void);
typedef struct GuardVfs GuardVfs;
int swarm_guard_admit(const char *, GuardVfs **);
int swarm_guard_open(GuardVfs *, sqlite3 **);
int swarm_guard_identity(GuardVfs *, struct stat *);
int swarm_guard_connection_identity(sqlite3 *, struct stat *);
int swarm_guard_connection_done(GuardVfs *);
int swarm_guard_dispose(GuardVfs *);
#endif
