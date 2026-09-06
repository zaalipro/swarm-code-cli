# Locked SQLite source snapshots

This closes the reproduced SHM mutation in the current schema integration.
Source and destination files belong to the CLI's existing schema/backup ownership
paths. The user goal authorizes this implementation in the CLI checkout. It does
not adopt the larger one-shot Repo capability design or permit canonical writes.

## Architecture

Use a small project-owned C executable, built at compile time and bundled under
the daemon's `priv/native/`, to copy source main/WAL files while holding the exact
SQLite Unix locks verified in the disposable experiment. It uses ordinary POSIX
file operations, does not load SQLite, and never writes source bytes or SHM.
The existing Exqlite library opens only the resulting private copy.

BEAM owns a fresh private workspace and precreates the three fixed files
`snapshot.db`, `snapshot.db-wal`, `snapshot.db-shm` with exact `0600` and exclusive
creation. Their identities are registered before the native helper starts. The
helper only fills the already-owned main/WAL inodes. It never creates, truncates,
renames or deletes files. BEAM retains responsibility for cleanup even if the
requesting process goes away. Do not infer cleanup authority from a filename seen
after helper failure.

`Platform.SourceSnapshot.with_snapshot(path, uid, expected, callback, opts)` runs
the callback against a private snapshot path after helper exit status confirms
the copy completed. The callback's result returns only after owned readers and
the workspace are closed. A dedicated owner monitors the requester and runs slow
copy/inspection work in monitored workers. It admits no second operation and
retains no complete source file in BEAM memory.

Use the existing bounded `ExternalCommand` owner for the native command. Observe
its actual process-owner exit before cleanup; its `cleanup_pending` outcome is not
proof of termination. Cancellation stops owned work, and ambiguous cleanup stays
owned with a typed `:snapshot_cleanup_pending` result. No detached native process
or successful schema result may outlive an incomplete cleanup.

## Native command contract

The helper accepts exactly these 20 arguments after its executable, all separately
passed via `spawn_executable`, with no shell interpolation:

1. literal `v1`
2. absolute source directory path, at most 16384 bytes
3. source basename, 1..255 bytes, excluding slash, NUL, `.` and `..`
4. source-directory device number
5. source-directory inode
6. trusted UID
7. source-main device number
8. source-main inode
9. source-WAL device number, or `-` for absent
10. source-WAL inode, or `-` for absent
11. source-SHM device number, or `-` for absent
12. source-SHM inode, or `-` for absent
13. destination-main device number
14. destination-main inode
15. destination-WAL device number
16. destination-WAL inode
17. destination-directory device number
18. destination-directory inode
19. timeout in milliseconds, 1..300000
20. maximum aggregate copy bytes, positive and at most signed 64-bit maximum

Every number is canonical unsigned decimal with overflow rejected before IO.
Device numbers are the raw `stat.st_dev` values corresponding to OTP's
`File.Stat.major_device`. Inode/device values are checked on the actual opened
descriptors. The working directory is the retained private destination workspace;
the helper opens `.` and verifies its identity and exact `0700`/UID. Source
directory and source files are independently opened no-follow and checked against
their expected identities. The source directory also requires exact `0700` and
the trusted UID, matching the BEAM admission check. Source basename operations are `openat`/`fstatat`
relative to the held source directory. Regular source/destination files require
exact `0600`, trusted UID, and no special permission bits. Destination files must
be empty when opened and must differ from all source inodes and one another.

Success is exactly one ASCII line `snapshot-v1 <main-bytes> <wal-bytes> <0|1>\n`
where the final value states WAL presence. No path or file content is returned.
Failure uses a nonzero status and no diagnostic source text. Output stays below
128 bytes. Source absence/presence and descriptor/path identity are checked again
before success. A rollback journal is refused; no recovery occurs on source.

## Locking and copying

Retain same-inode read-only and locks-only read/write main descriptors until all
locks are released. Taking a writable descriptor authorizes locking only. For
existing SHM, open it for locks only, coordinate the DMS byte and nonblockingly
lock WRITE/CKPT/RECOVER (120..122) exclusively. Preserve normal reader locks;
holding all reader slots caused `SQLITE_PROTOCOL` in the rejected prototype.
For absent SHM, upgrade to the SQLite main exclusive lock and recheck absence
before copying. Main-only databases use that same exclusive path. Contention
refuses without copying; it is never forced or repaired.

Copy through a fixed 65536-byte buffer with complete short-read/write handling,
byte-count overflow checks and a deadline. Check stdin closure and a signal-set
cancellation flag between chunks. Source descriptors remain open through the
complete copy and final identity/size/mode checks. Sync destination descriptors
before success. Never invoke SQLite on source, use immutable hints, copy source
SHM, or hold private SHM beside live source main/WAL.

The native constants are tied to the pinned SQLite Unix lock layout. Compilation
uses C11 with `-Wall -Wextra -Werror`, no new third-party dependency, and no runtime
compiler/download fallback. The Mix compiler emits the target-native executable
under daemon `priv/native/`; release packaging inherits that path. Linux/macOS
source compatibility is required; native platform acceptance remains separately
reported at actual scope.

## Integration and evidence

Schema Probe uses SourceSnapshot before inspecting SQLite and preserves its
existing original-source Binding and post-probe identity checks. Remove its
hard-link-open path and prefix-scan deletion. Existing hooks remain test-build
only and cannot mutate another source by returning a new path.

Backup first obtains the same locked snapshot in the main VM. A monitored bridge
lets its existing Gate process retain its ownership dictionary. Before opening
SQLite, the external broker copies every supplied snapshot file into its own
precreated, receipt-owned inodes and returns their actual identities. It shares
no source or snapshot inode with SQLite. This additional complete copy makes a
snapshot callback timeout independent of the broker reader lifetime; it costs
one extra copy until the ownership APIs can safely support direct transfer.
The Gate releases the snapshot and waits for cleanup before returning a successful
backup result. Requester death cancels the bridge, and each owner cleans only its
own files. Existing original-source metadata/fingerprint/reprobe checks remain.
Current-ready backups remain explicitly requested.

Tests retain all three failing live-WAL no-mutation regressions, then add successful
WAL and missing-SHM probe reads, ordinary lock contention, bounded cancellation,
requester death, output identity refusal, native failure cleanup, and a broker
backup using fresh unprewarmed WAL. Exact original source bytes and full copied
values are checked. No native acceptance or full parity claim follows from local
tests. Finish with code review, full precommit and production compile.
