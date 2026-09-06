# Owned shell command guardian

Build with a POSIX C11 compiler. The daemon Mix compiler packages the binary as
`priv/native/swarm-tool-command`; it is not a runtime compiler dependency.

Arguments are `timeout_ms` (1–600000) and a single `/bin/sh -c` command. The daemon
sets cwd and the cleaned child environment. Child stdin is `/dev/null`. The
helper's own stdin belongs to its requesting BEAM Port; EOF cancels the job even
when the task is killed with an untrappable exit. The helper must remain outside
the shell job's process group.

Stdout uses unsigned big-endian four-byte packet lengths. The packet body is:

- `D` followed by at most 8192 bytes of combined shell stdout/stderr.
- `X` followed by an unsigned big-endian four-byte exit status.
- `T` for a command deadline.
- `C` for confirmed cooperative cancellation.

Stdin accepts packet4 `A` to acknowledge one data packet and packet4 `C` to
cancel. A terminal packet must be acknowledged with packet4 `F`; the helper
keeps stdin open until this acknowledgment so trailing data credits cannot race
a pipe closure. At most four data packets may be unacknowledged. The guardian continues
polling the deadline and cancellation pipe while output is backpressured. A
cooperative cancellation returns only after the guardian has sent its terminal
packet and the Port has observed the exact helper exit status.

Normal completion, timeout and cancellation terminate remaining members of the
owned POSIX process group. A launch handshake ensures the child has established
its session before it can spawn descendants. `waitid(..., WNOWAIT)` retains the
session leader's identity until group TERM/KILL cleanup is sent. The helper never
looks up or signals arbitrary PIDs. Linux additionally adopts and reaps its own
orphaned descendants with `PR_SET_CHILD_SUBREAPER`.

This is process-group ownership, not an operating-system sandbox. Commands that
explicitly change process group/session (`setpgid`, `setsid`, daemonization) are
unsupported. These require stronger platform-specific containment before claiming
arbitrary descendant ownership. Shell commands themselves are execute-permission
operations and may access paths outside the project; file-tool confinement does
not turn `/bin/sh` into a filesystem sandbox.

Verified locally on macOS: fixture script success/nonzero exit, closed stdin,
bounded output, deadline, task death and background-job cleanup. Linux source is
present but requires Linux-native acceptance; Windows is unsupported.
