#ifndef SWARM_LEASE_H
#define SWARM_LEASE_H
#include <sys/stat.h>
typedef struct SwarmLease SwarmLease;
typedef int (*SwarmLeaseValidate)(void *);
int swarm_lease_acquire(int, SwarmLeaseValidate, void *, SwarmLease **);
int swarm_lease_assert(SwarmLease *);
int swarm_lease_identity(SwarmLease *, struct stat *);
int swarm_lease_close(SwarmLease *);
int swarm_lease_active(SwarmLease *);
void swarm_lease_free(SwarmLease *);
#ifdef SWARM_GUARD_TEST
int swarm_lease_test_install_close_hook(void);
void swarm_lease_test_restore_close_hook(void);
typedef struct SwarmLeaseTestFault {
    int site;
    int hits;
} SwarmLeaseTestFault;
int swarm_lease_acquire_test(int, SwarmLeaseValidate, void *, SwarmLeaseTestFault *, SwarmLease **);
#endif
#endif
