# macOS platform identity helper

This read-only helper accepts only `identity PID` and `desktop`. It opens no
application database and sends no process signals. It emits one JSON line of at
most 2048 bytes and returns a nonzero status without diagnostic content when a
trusted observation is unavailable.

`identity` uses libproc's BSD process information for real/effective UID, PID,
and the process-start seconds/microseconds tuple; it checks the tuple twice to
reject observed PID reuse. The boot UUID comes from `kern.bootsessionuuid`.

`desktop` uses NSWorkspace application identities, then enumerates kernel PIDs
and inspects same-UID executable ancestry with libproc. Only an actual enclosing
`.app` bundle whose identifier is exactly `com.zaali.swarmcode` matches. This also
covers a BEAM descendant and an executable still inside the bundle after its
launcher exits. `sysctl(KERN_PROC_PID)` establishes UID boundaries before
inspecting protected foreign-UID ancestors such as a root login process. Unknown
same-UID observations fail closed; no process-name substring is used.

The daemon Mix native compiler builds the helper with warnings treated as errors
and applies an ad-hoc code signature. Platform.MacOS compiles the resulting
signed bytes' SHA-256 into the BEAM module and checks that pin, file permissions,
and `codesign --verify --strict` before executing it through a bounded Port.
Changing or re-signing the helper without recompiling the pin fails closed.
These source-build artifacts are **internal**, not a signed public Mac release.
A release must Developer ID sign this helper before compiling the pin, sign the
complete package, notarize it, and verify Gatekeeper/quarantine handling. Build
and installation directories are trusted same-user/release-owned inputs; this
is not isolation from an attacker who can replace the running Elixir code.

The current desktop does not honor the CLI database lease. Pre/post detection
cannot prevent the desktop from starting after the second check. Concurrent
CLI/desktop database use remains unsupported; quit the desktop first, and stop
the CLI before reopening it.

Set `SWARM_MACOS_SIGN_IDENTITY` to a Developer ID identity for release builds;
the Mix compiler passes that identity directly to `codesign` before the helper
digest is compiled into the BEAM. The default `-` identity is ad-hoc and must
not be used for public release artifacts.
