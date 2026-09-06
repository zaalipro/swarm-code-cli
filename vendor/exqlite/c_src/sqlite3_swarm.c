#if defined(__clang__) || defined(__GNUC__)
/* Pristine enabled SQLite math/rtree callbacks contain unused formal arguments.
 * Keep this suppression around upstream bytes only; guard/NIF warnings are errors. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#endif
#include "sqlite3.c"
#if defined(__clang__) || defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
#ifdef SWARM_GUARD_TEST
#if !SQLITE_OS_UNIX || OS_VXWORKS
#error Guard feasibility requires the pinned POSIX Unix VFS
#endif
#include "swarm_guard_vfs.c"
#endif

#if SQLITE_OS_UNIX && !OS_VXWORKS
#include "swarm_lease_vfs.c"
#endif
