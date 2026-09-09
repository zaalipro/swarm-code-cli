#ifndef SWARM_BINDING_H
#define SWARM_BINDING_H
#include "sqlite3.h"
typedef struct SbBinding SbBinding;
int swarm_bound_admit(int parent, int main_fd, const char *dbname, SbBinding **out);
int swarm_bound_open(SbBinding *, sqlite3 **);
int swarm_bound_close(SbBinding *, sqlite3 *);
int swarm_bound_assert(SbBinding *);
int swarm_bound_dispose(SbBinding *);
void swarm_bound_health(SbBinding *, int (*)(void *), void (*)(void *), void *);
int swarm_bound_install_close_hook(void);
int swarm_bound_close_status(SbBinding *);
#ifdef SWARM_GUARD_TEST
void swarm_bound_test_close_fault(SbBinding *);
int swarm_bound_test_close_hits(SbBinding *);
#endif
#endif
