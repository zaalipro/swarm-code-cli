#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

static NSString *const bundleID = @"com.zaali.swarmcode";
static int emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (!data || data.length > 2047) return 1;
    if (fwrite(data.bytes, 1, data.length, stdout) != data.length || putchar('\n') == EOF) return 1;
    return 0;
}
static BOOL info(pid_t pid, struct proc_bsdinfo *out) {
    memset(out, 0, sizeof(*out));
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, out, sizeof(*out)) == sizeof(*out);
}
/* macOS may deny libproc for protected processes owned by another UID. Query
 * kernel credentials before ancestry inspection so a root login parent is a
 * known boundary rather than an unavailable same-UID process. */
static int owner(pid_t pid, uid_t *uid) {
    struct kinfo_proc process;
    memset(&process, 0, sizeof(process));
    size_t size = sizeof(process);
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &process, &size, NULL, 0) != 0) return -1;
    if (size == 0) return 0;
    if (size != sizeof(process)) return -1;
    *uid = process.kp_eproc.e_ucred.cr_uid;
    return 1;
}
static int identity(const char *value) {
    char *end = NULL;
    errno = 0;
    long requested = strtol(value, &end, 10);
    if (errno || !end || *end || requested < 1 || requested > INT_MAX) return 1;
    pid_t pid = (pid_t)requested;
    struct proc_bsdinfo first, second;
    char boot[128] = {0}; size_t length = sizeof(boot);
    if (!info(pid, &first) || first.pbi_uid != getuid() || first.pbi_ruid != getuid() ||
        sysctlbyname("kern.bootsessionuuid", boot, &length, NULL, 0) != 0 ||
        length < 2 || length >= sizeof(boot) || !info(pid, &second) ||
        first.pbi_start_tvsec != second.pbi_start_tvsec || first.pbi_start_tvusec != second.pbi_start_tvusec ||
        first.pbi_uid != second.pbi_uid) return 1;
    NSString *bootID = [[NSString alloc] initWithUTF8String:boot];
    if (!bootID || ![[NSUUID alloc] initWithUUIDString:bootID]) return 1;
    return emit(@{@"version": @1, @"kind": @"identity", @"uid": @(first.pbi_uid), @"pid": @(pid),
                  @"start": [NSString stringWithFormat:@"%llu:%06llu", first.pbi_start_tvsec, first.pbi_start_tvusec],
                  @"boot": bootID});
}
/* Resolve actual executable ancestors, including nested app bundles. No name matching. */
static BOOL desktopExecutable(NSString *executable) {
    NSString *path = [executable stringByResolvingSymlinksInPath];
    for (NSUInteger depth = 0; depth < 128 && path.length > 1; ++depth) {
        if ([[path pathExtension] isEqualToString:@"app"]) {
            NSBundle *bundle = [NSBundle bundleWithPath:path];
            if ([[bundle bundleIdentifier] isEqualToString:bundleID]) return YES;
        }
        path = [path stringByDeletingLastPathComponent];
    }
    return NO;
}
static int ancestry(pid_t pid, uid_t uid) {
    pid_t previous = 0;
    for (int depth = 0; depth < 128 && pid > 1; ++depth) {
        uid_t process_uid;
        int present = owner(pid, &process_uid);
        if (present == 0 || (present == 1 && process_uid != uid)) return 0;
        if (present < 0) return -1;
        struct proc_bsdinfo before, after;
        if (!info(pid, &before)) return (errno == ESRCH || errno == ENOENT) ? 0 : -1;
        if (before.pbi_uid != uid || before.pbi_ruid != uid) return 0;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) return (errno == ESRCH || errno == ENOENT) ? 0 : -1;
        if (!info(pid, &after) || before.pbi_start_tvsec != after.pbi_start_tvsec ||
            before.pbi_start_tvusec != after.pbi_start_tvusec || before.pbi_ppid != after.pbi_ppid) return -1;
        NSString *executable = [[NSString alloc] initWithUTF8String:path];
        if (!executable) return -1;
        if (desktopExecutable(executable)) return 1;
        previous = pid;
        pid = (pid_t)before.pbi_ppid;
        if (pid == previous) return -1;
    }
    return pid <= 1 ? 0 : -1;
}
static int desktop(void) {
    uid_t uid = getuid();
    /* NSWorkspace sees application identity, including launch-time wrappers. */
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (![app.bundleIdentifier isEqualToString:bundleID]) continue;
        struct proc_bsdinfo process;
        if (!info(app.processIdentifier, &process)) return 1;
        if (process.pbi_uid != uid || process.pbi_ruid != uid) continue;
        int match = ancestry(app.processIdentifier, uid);
        if (match != 1) return 1;
        return emit(@{@"version": @1, @"kind": @"desktop", @"active": @YES,
                      @"pid": @(app.processIdentifier), @"uid": @(uid), @"application": bundleID});
    }
    /* Enumerate same-UID executables and ancestry to catch detached BEAM children. */
    int count = proc_listallpids(NULL, 0);
    if (count <= 0 || count > 65536) return 1;
    int capacity = count + 1024;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return 1;
    count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    if (count < 0 || count >= capacity) { free(pids); return 1; }
    for (int i = 0; i < count; ++i) {
        if (pids[i] <= 1) continue;
        uid_t process_uid;
        int present = owner(pids[i], &process_uid);
        if (present == 0 || (present == 1 && process_uid != uid)) continue;
        if (present < 0) { free(pids); return 1; }
        struct proc_bsdinfo process;
        if (!info(pids[i], &process)) {
            if (errno == ESRCH || errno == ENOENT) continue;
            free(pids); return 1;
        }
        if (process.pbi_uid != uid || process.pbi_ruid != uid) continue;
        int match = ancestry(pids[i], uid);
        if (match < 0) { free(pids); return 1; }
        if (match == 1) {
            pid_t active = pids[i]; free(pids);
            return emit(@{@"version": @1, @"kind": @"desktop", @"active": @YES,
                          @"pid": @(active), @"uid": @(uid), @"application": bundleID});
        }
    }
    free(pids);
    return emit(@{@"version": @1, @"kind": @"desktop", @"active": @NO});
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "identity") == 0) return identity(argv[2]);
        if (argc == 2 && strcmp(argv[1], "desktop") == 0) return desktop();
        return 1;
    }
}
