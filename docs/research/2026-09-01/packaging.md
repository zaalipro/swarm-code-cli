# SwarmCode CLI/TUI packaging and single-command installation research

**Status:** read-only research, 2026-09-01. No files in `/Users/zaali/dev/swarm-code` were changed and the requested new repository was not initialized by this research task.

## Executive decision

Use **four target-native, relocatable Mix release archives with `include_erts: true`** as the reliability baseline. Deliver those same immutable artifacts through two user experiences:

1. **Universal direct installer (primary on Ubuntu):** a no-root, per-user HTTPS installer, invoked with one `curl … | sh` command, which selects the OS/CPU artifact, verifies it, and installs it atomically under XDG directories.
2. **Homebrew tap (primary convenience on macOS, secondary on Linux):** `brew install zaalipro/tap/swarm-code`, using the same prebuilt, checksummed artifacts rather than rebuilding OTP on the user's machine.

Publish the archives, checksums, signatures/attestations, SBOMs, and manual install instructions on an **immutable GitHub Release**. A GitHub Release is the source of truth; the direct installer and Homebrew formula are delivery layers, not separate builds.

Do **not** make Burrito the first production packaging foundation. Burrito 1.6.0 is active and is the strongest current Elixir option when a literal one-file executable is required, but its own documentation still calls the approach experimental. It introduces first-run extraction, an extra Zig wrapper, native-dependency cross-compilation behavior, old-payload cleanup that conflicts with rollback, and an unproven SwarmCode-specific macOS signing/notarization path. Evaluate it in a bounded second-phase spike after plain releases pass the four-target acceptance suite. Do not use Bakeware: its repository is archived and its last Hex release was in 2022.

The central distinction is:

- **Single command** is an installation UX requirement.
- **Single file** is an artifact-layout requirement.

The former does not require the latter. A verified archive installed by one command is simpler and more reliable than a self-extracting executable.

## Decisions that the product owner must make explicitly

These choices materially alter packaging scope:

1. **Meaning of “Elixir bundled.”** Recommended meaning: the app ships ERTS plus the Elixir/OTP libraries it needs, so no system Erlang or Elixir is required. It should not expose general-purpose `elixir`, `iex`, `mix`, compilers, or source code. Shipping a user-facing Elixir toolchain is a larger artifact and a different security/support promise.
2. **Developer-tool prerequisites.** SwarmCode currently calls system `git`; PR creation additionally detects `gh`; arbitrary MCP servers may need Node, Python, or other runtimes. Recommended phase-one contract: Git is a documented prerequisite, `gh` is optional, and MCP runtimes are user-provided. “No prerequisites for every feature” would require bundling and maintaining a portable Git/SSH/CA stack plus an open-ended set of MCP runtimes, which is not achieved merely by bundling Elixir.
3. **Minimum OS contract.** Recommended initial claim: macOS 14+ and Ubuntu 22.04 LTS+ on arm64 and x86_64. A broader claim must have real minimum-version smoke runners, not just compilation flags.
4. **Apple distribution credentials.** Production-quality macOS downloads need a paid Apple Developer account, Developer ID Application signing identity, and notarization credentials. A stapled installer additionally needs a Developer ID Installer identity.
5. **Install URL.** Prefer a controlled HTTPS endpoint such as `https://get.swarmcode.dev` that redirects only to immutable release material. If no domain is available, use a GitHub Release asset URL, never a mutable `main/install.sh` raw URL as the documented production command.

## What “single command” should mean

### Supported promises

For the direct route, “single command” should mean all of the following:

- The user enters one shell invocation, for example `curl --proto '=https' --tlsv1.2 -fsSL https://get.swarmcode.dev | sh`.
- No Erlang, Elixir, Mix, compiler, package manager, or root access is needed.
- The installer detects Darwin/Linux and arm64/x86_64; rejects unsupported combinations rather than guessing.
- It resolves either the stable channel or an explicitly requested version, downloads an immutable asset, verifies its SHA-256 and release identity/provenance when the verifier is available, extracts safely, and atomically switches the active version.
- Failure leaves the prior installation usable. A repeat installation is idempotent.
- It never runs a downloaded application artifact before verification.
- It prints the exact installed version, path, verification status, and next command.

This promise still has honest limits:

- It requires an HTTPS downloader (`curl` for the canonical command; a separately documented `wget` variant may be offered) plus normal archive/checksum tools. Minimal Ubuntu images do not guarantee `curl`.
- A child installer cannot change the environment of the already-running parent shell. A no-root install to `~/.local/bin` can be invoked immediately by its full path, but bare `swarm-code` may require opening a new shell or a pre-existing PATH entry. Do not silently edit shell startup files merely to hide this Unix constraint; offer an explicit `--modify-path` opt-in.
- The install can be one command while Git, network credentials, model-provider access, and optional MCP runtimes remain separate prerequisites.

Never document `curl … | sudo sh`. The direct path should be per-user and no-root. System-wide installation should be an explicit, separate mode with an inspectable downloaded installer or a package manager.

### Installation entry points

| Entry point | User-visible invocation | Prerequisites | Recommended role |
|---|---|---|---|
| Direct stable installer | one `curl … | sh` command | `curl`, `sh`, archive/checksum utilities | Primary Ubuntu path; universal fallback |
| Homebrew tap | `brew install zaalipro/tap/swarm-code` | working Homebrew | Primary macOS convenience path; secondary Linux path |
| Pinned direct installer | same command with an explicit `--version X.Y.Z` argument | same as direct | Reproducible CI and rollback/recovery |
| GitHub CLI | `gh release download …` plus install action | `gh`; normally more than download alone | Verification/manual recovery, not primary install UX |
| Manual archive | download, verify, extract | several user actions | Auditable and offline fallback |

Homebrew on Linux is not a substitute for the direct Ubuntu installer. Current Homebrew Tier 1 Linux requires glibc 2.39 or newer; Ubuntu 22.04 carries glibc 2.35, placing that common target outside Tier 1 even though Homebrew may install its own glibc.

## Separate artifact technology from distribution channel

Mix releases, Burrito, Bakeware, and custom self-extractors determine **what is built**. GitHub Releases, Homebrew, `curl | sh`, apt, Snap, and `gh` determine **how it reaches a user**. Comparing them as one flat list hides important combinations: a plain Mix release archive can still be installed with a single command, and a Burrito binary still needs a trustworthy download/update channel.

### Artifact choices

| Artifact approach | Bundles ERTS/Elixir runtime | Benefits | Material risks/limits | Decision |
|---|---:|---|---|---|
| Plain `mix release` directory, compressed per target | Yes by default (`include_erts: true`) | Official Elixir mechanism; transparent layout; fewest moving parts; straightforward native signing and dependency inspection; easy versioned installs | Not a literal single file; must build on a compatible target and archive it; dynamic ERTS/NIF dependencies remain the packager's responsibility | **Production baseline** |
| Burrito 1.6 self-extracting wrapper | Yes | Literal one-file download; Darwin/Linux arm64/x86_64 targets; bundles BEAM, ERTS, and supported `elixir_make` NIF artifacts; maintenance metadata/unpack handling | Project labels approach experimental; requires Zig/XZ at build time; first-run extraction; extra updater/plugin attack surface; generic NIF cross-build assumptions; old-payload auto-removal complicates rollback; signing/notarization must cover final wrapper and extracted native code | **Phase-two evaluation only** |
| Bakeware | Yes | Established the Elixir self-extracting design; single binary | Repository archived; latest Hex/release 0.2.4 dates to 2022; internal archive format documents SHA-1; no current maintenance basis | **Reject** |
| Custom POSIX shell self-extracting archive | Indirectly | Easy prototype | Depends on shell/tar behavior; difficult safe extraction and concurrency; no native macOS signing identity for the launcher; no advantage over an installer plus archive | **Reject** |
| Custom C/Rust/Zig self-extractor | Yes if implemented | Full control; literal one file | Reimplements Burrito's hardest security, extraction, update, and portability work; new native code and signing surface | **Reject unless requirements exceed Burrito** |
| Escript or Mix archive | No ERTS | Small and simple | Requires a compatible Erlang installation; therefore fails the bundled-runtime requirement | **Reject** |
| OCI/Docker image | Runtime in image | Reproducible server environment | Docker prerequisite, awkward TTY/project filesystem/SSH integration, poor native CLI UX | Optional CI/demo only |
| Linux AppImage | Can bundle userland | One Linux file | Linux-only, FUSE/extraction variance, still has glibc/kernel and update/signing concerns, offers no benefit for macOS | Do not prioritize |
| Nix closure/flake | Yes through closure | Strongly reproducible, clean rollback | Nix prerequisite and a separate packaging ecosystem | Optional community channel |

### Distribution choices

| Channel | Strengths | Weaknesses | Decision |
|---|---|---|---|
| Immutable GitHub Release assets | Canonical versioned artifacts; globally available; current GitHub immutable releases lock tag and assets; integrates attestations | By itself is a download page, not installation UX | **Source of truth** |
| Direct HTTPS installer | Works without a package manager; can be no-root and cross-platform; one command | Piped bootstrap runs before it can verify itself; PATH and standard-tool constraints; updater/uninstaller must be maintained | **Primary universal route** |
| Homebrew tap formula/cask | Familiar one-command install/upgrade/uninstall; SHA-256 enforced; native completion locations; handles OS/arch selection | Homebrew prerequisite; Linux support floor differs from Ubuntu target; third-party tap trust; formula must not rebuild OTP unexpectedly | **Primary macOS convenience route** |
| GitHub CLI | Excellent `gh attestation verify`, immutable-release and release-asset verification | `gh` is not guaranteed and download is not installation | Verification/manual route |
| `.deb` in apt repository/PPA | Native Ubuntu dependency, upgrade, remove/purge, repo signatures | Repository bootstrap is not one command unless wrapped; root/system-wide; four Ubuntu/arch builds or careful binary package; operating a signed apt repo | Later enterprise channel |
| Snap classic | Ubuntu often has Snap; store signing, auto-updates, channels and `snap revert` | Linux-only; broad coding-agent filesystem/process access likely needs classic confinement and review; path/sandbox surprises | Later optional channel |
| Signed/notarized macOS `.pkg` | Stapled ticket supports offline Gatekeeper verification; system PATH install | Root prompt; package uninstall is weak unless separately engineered; separate artifact behavior | Optional high-assurance macOS route |

Do not disguise the application as a GitHub CLI extension. `gh extension install` is useful for tools whose intended invocation is `gh <name>`, but it makes GitHub CLI a runtime prerequisite and does not provide the standalone `swarm-code` command or the desired general developer-tool distribution contract.

## Target and compatibility contract

### Recommended initial artifacts

Use explicit filenames and metadata; do not call a binary merely `linux` or `macos` without its ABI and CPU.

| Artifact | CPU/ABI | Build environment | Initial runtime contract |
|---|---|---|---|
| `swarm-code-V-macos-arm64` | Apple arm64/Darwin | native GitHub macOS arm64 runner, pinned image | macOS 14+ on Apple Silicon |
| `swarm-code-V-macos-x86_64` | Intel x86_64/Darwin | native Intel macOS runner | macOS 14+ on supported Intel Mac |
| `swarm-code-V-ubuntu-22.04-x86_64` | x86_64-linux-gnu, glibc floor 2.35 | native x64 Ubuntu 22.04 container/runner | Ubuntu 22.04, 24.04, 26.04 |
| `swarm-code-V-ubuntu-22.04-arm64` | aarch64-linux-gnu, glibc floor 2.35 | native arm64 Ubuntu 22.04 container/runner | Ubuntu 22.04, 24.04, 26.04 |

The supported claim must be narrower than “Linux.” A build on Ubuntu 22.04 can set a glibc 2.35 symbol floor and can be tested forward on newer Ubuntu LTS releases. A binary built on Ubuntu 24.04/glibc 2.39 will generally not run on 22.04. The established guidance is to build on the oldest userspace one intends to support. Do not bundle or replace glibc inside a normal GNU/Linux release; instead bundle non-core libraries or produce a separate musl target.

For each Linux artifact, enforce the baseline in CI by checking ELF architecture, interpreter, NEEDED entries, RPATH/RUNPATH, and maximum referenced `GLIBC_*` symbol version for **every** ERTS executable, port executable, NIF, and bundled helper. Smoke-test on the minimum OS and every claimed newer LTS. `ldd` on only the top-level launcher is insufficient.

A fully static musl artifact may later help other distributions, but it is a separate ABI (`*-linux-musl`) and needs its own DNS, TLS, PTY, NIF, and terminal tests. It should not silently replace the Ubuntu/glibc artifact.

On macOS, ship separate arm64 and x86_64 archives. Do not rely on Rosetta and do not build a nominal “universal” archive by combining only the outer executable: ERTS contains multiple native executables and the release contains native NIFs. A genuine universal2 release would have to merge and validate every Mach-O payload, yielding complexity with no user benefit because the installer can select an architecture.

Set and record a deployment target for all macOS native compilation, then test on that exact minimum. A compiler flag alone is not an acceptance test. Current GitHub-hosted labels include macOS arm64 and Intel runners, but the minimum Intel OS may require a dedicated/self-hosted runner if GitHub no longer hosts it.

## Bundled runtime and native dependencies

### What a Mix release guarantees—and what it does not

Official Mix documentation says a release is self-contained and includes ERTS by default, so the target does not need Erlang or Elixir installed. It also says the release must match target architecture, OS/vendor, and ABI, and warns that ERTS and NIFs may dynamically require libraries such as OpenSSL. There is no official general cross-compilation path between arbitrary target triples.

Therefore use `include_erts: true`, but do not equate it with “all native dependencies are automatically portable.” Build and inspect each target artifact.

The CLI release should be a dedicated release/application profile that excludes the desktop stack. Read-only inspection of the current app shows `:desktop`, `:desktop_deployment`, DBus/wx packaging, and a desktop-specific launcher with GTK/GStreamer library variables. Carrying that release graph into the TUI would unnecessarily bundle GUI frameworks and create substantial Linux/macOS native-dependency and signing work. The CLI should retain reusable engine/storage/provider functionality but not boot elixir-desktop or desktop deployment.

### SQLite / Exqlite

The current app uses Ecto SQLite through Exqlite, which is a NIF and is the main known production native dependency once desktop components are excluded. Current Exqlite release assets include NIFs for:

- `aarch64-apple-darwin`
- `x86_64-apple-darwin`
- `aarch64-linux-gnu`
- `x86_64-linux-gnu`
- corresponding musl targets

Exqlite normally embeds/compiles the SQLite amalgamation unless configured to use a system SQLite library. For release control:

- Pin Exqlite and the NIF ABI through `mix.lock`.
- Prefer target-native compilation in each release job, or at minimum copy and verify the exact precompiled NIF during the build. Do not allow a first-run NIF download.
- Do not set `EXQLITE_USE_SYSTEM=1`; a system SQLite dependency defeats the self-contained contract and can change features across hosts.
- Sign the final Exqlite `.so` on macOS and inspect its linked libraries on all platforms.
- Run an artifact-level create/migrate/write/read/integrity smoke test, not just a module load.
- Any SQLite extension must be compiled and packaged for all four targets.

Repeat the same inventory for every future Rustler, `elixir_make`, C/C++, or port dependency. Burrito's automatic recompilation specifically targets supported `elixir_make` NIFs; it is not proof that arbitrary Rustler or precompiled native assets are correct.

### ERTS libraries and terminal dependencies

For a CLI/TUI-oriented OTP build:

- Omit wx and GUI applications.
- Inventory ERTS linkage to OpenSSL, ncurses/termcap/tinfo, zlib, libstdc++, and platform frameworks.
- Either build compatible dependencies into the release with local RPATHs or establish a minimum OS dependency. Never solve this with a broad global `LD_LIBRARY_PATH` that can affect child tools.
- Keep the OS trust store or a deliberately bundled CA bundle policy explicit and updateable.
- Bundle time-zone data and fonts/terminal assets needed for offline startup; current app intentionally disables tzdata auto-update, so release preparation must refresh it.
- Ensure the launcher uses `exec` semantics so SIGINT, SIGTERM, terminal resize, suspend/resume, and exit codes reach the BEAM correctly.
- Disable Erlang distribution unless the CLI genuinely needs it; it otherwise adds an `epmd` process, cookie, port, and cleanup/security surface.

“Offline” should mean the installed binary starts, renders the TUI, reads projects, runs local engine/storage features, and never downloads a runtime, NIF, asset, or migration. Provider calls, Tavily/web search, remote Git operations, and network MCP servers naturally still need connectivity.

### External developer tools

Read-only inspection of the current implementation found system calls to `/bin/sh`, `git`, `ps`, `kill`, `df`, platform openers, optional `gh`, and arbitrary configured MCP executables. Most base process utilities are present on macOS/Ubuntu; Git and `gh` are not guaranteed.

Recommended contract:

- Require a supported Git version and provide an actionable startup diagnostic.
- Let Homebrew declare/install Git as a dependency if desired.
- In the direct installer, do not run `apt` or macOS GUI developer-tool installers behind the user's back. Detect Git and explain which features need it.
- Keep `gh` optional; PR creation explains how to install/authenticate it.
- Treat Node/Python/etc. as requirements of the selected MCP server, not of SwarmCode core.

If “all functionality from a pristine OS in one command” is literal, this prerequisite decision must be reopened before implementation.

## macOS signing, hardened runtime, notarization, and quarantine

A production macOS pipeline should perform these steps on both architecture artifacts:

1. Enumerate every Mach-O executable and dynamic library in ERTS, NIFs, and bundled helpers.
2. Sign nested code inside-out with **Developer ID Application**, secure timestamping, and hardened runtime. Do not use `codesign --deep` as a substitute for deterministic enumeration.
3. Determine the minimum entitlements empirically. BEAM JIT under hardened runtime may need `com.apple.security.cs.allow-jit`; do not grant broader unsigned-memory, DYLD, or disabled-library-validation exceptions unless a failing native test proves they are required.
4. Sign the final outer launcher/wrapper last. Any mutation after signing invalidates the signature. This is especially important for a Burrito binary whose payload is appended to a Zig wrapper.
5. Verify signatures (`codesign`), policy assessment (`spctl`), architecture/linkage (`file`, `lipo`, `otool`), and launch under a simulated quarantined clean-user scenario.
6. Package with Apple's supported container format and submit with `xcrun notarytool`; inspect the full notary log and require acceptance.
7. Never tell users to remove quarantine with `xattr`, bypass Gatekeeper, or create a “security exemption.”

Apple's current documentation says the notary service accepts UDIF disk images, signed flat installer packages, and ZIP archives. It also says a ZIP itself cannot be stapled and a notarization ticket cannot currently be stapled to a standalone binary. Consequently:

- A signed/notarized ZIP or archive is suitable for the direct/Homebrew path; Gatekeeper can obtain the ticket online when quarantine applies.
- If offline Gatekeeper verification is a hard requirement, additionally produce a Developer ID Installer-signed, notarized, **stapled `.pkg`**. This is a separate high-assurance channel, not the default no-root installer.

For updates, never overwrite a running signed executable in place. Apple documents signature-cache problems from in-place replacement. Version directories plus atomic pointer/symlink replacement naturally avoid this and also enable rollback.

Burrito deserves a specific signing gate: confirm that signing the completed wrapper does not disturb its payload offsets; confirm every extracted executable/NIF is independently valid; launch a quarantined final asset on clean arm64 and Intel Macs; and notarize the exact delivered bytes. Do not infer this from Burrito merely reporting “no runtime dependencies.”

## Supply-chain integrity

### Release contents

Every versioned release should contain, for each of the four artifacts:

- final signed archive/binary
- SHA-256 entry in a deterministic `SHA256SUMS`
- detached cryptographic signature/bundle for the checksum manifest and/or artifact
- GitHub build-provenance attestation for the final artifact
- CycloneDX or SPDX SBOM attestation tied to the final artifact digest
- human-downloadable SBOM
- third-party licenses/notices
- release manifest containing product version, Git commit, OTP, Elixir, SQLite/Exqlite, target triple, minimum OS/glibc, byte size, digest, and build workflow identity

Create the GitHub Release as a draft, attach and verify all assets, then publish with **immutable releases enabled**. Current GitHub immutable releases lock the tag and release assets after publication and GitHub supports `gh release verify` / `verify-asset`.

Generate a dependency-aware Elixir SBOM from the locked Mix graph—EEF Security WG's current `sbom` package supports CycloneDX and system dependencies—and merge/augment it with an artifact filesystem/native-library inventory. A generic binary scan alone can miss BEAM dependency semantics. Include OTP, Elixir, Exqlite/SQLite, any bundled OpenSSL/terminal library, native helpers, JS/assets if any, and the installer/updater.

GitHub artifact attestations use Sigstore and can capture workflow/repository/commit provenance; GitHub's current `actions/attest` flow also accepts an SBOM path. Attestations provide value only when verified. Document `gh attestation verify` online and publish the attestation bundle/trusted-root procedure for air-gapped verification.

Use two complementary signature forms rather than inventing one overloaded mechanism:

- GitHub/Sigstore keyless attestations bind final artifact digests to the protected repository workflow and transparency log.
- Sign `SHA256SUMS` with a long-lived offline Ed25519 release key (for example Minisign), publish/fingerprint the public key through multiple independent locations, and document offline verification. The piped installer may enforce this only when a trusted verifier already exists; downloading an unverified verifier from the same compromised endpoint is circular.

Compute public digests and attestations only after every byte-changing step. In particular, sign nested macOS code before archiving; and if a `.pkg` is stapled, checksum/attest the final stapled package, not the pre-staple file.

### Direct-installer trust boundary

The piped bootstrap is executed before it can verify itself; TLS and control of the install domain are the bootstrap trust anchors. Be explicit about this rather than claiming SHA-256 solves it. Mitigations:

- Serve only over HTTPS and restrict redirects to HTTPS on controlled/GitHub asset hosts.
- Keep the bootstrap tiny, reviewable, and versioned; publish its checksum/signature and a safer two-step “download, inspect/verify, run” alternative.
- Resolve a strict semantic version/channel manifest, never evaluate remote shell or JSON fields.
- Download the application artifact to a `0700` temporary directory with `umask 077`.
- Verify an exact SHA-256 line before extraction. Reject missing/duplicate entries.
- If `gh` or a supported verifier is present, also require the expected repository/workflow provenance. The simple path may report “digest verified; provenance verifier unavailable” rather than silently claiming full authenticity.
- Validate archive paths before extraction: reject absolute paths, `..`, unsafe device entries, and escaping symlinks.
- Bound downloads and clean every temporary file on success, failure, signal, and timeout.

Homebrew independently pins SHA-256 in its formula/cask metadata. That establishes exact bytes but, as Homebrew itself notes, still requires trust in the reviewed metadata/vendor. Apple signing/notarization and GitHub provenance provide independent identity signals.

Pin release workflow actions by commit SHA, use protected tags/environments, grant least-privilege `contents`, `id-token`, and `attestations` permissions, and expose signing secrets only in tag release jobs. Build PR artifacts unsigned and never make untrusted PR code eligible to access Apple credentials.

## Installation layout, update, rollback, and uninstall

### XDG layout

Use XDG semantics on both Ubuntu and macOS for the CLI unless compatibility with the desktop app deliberately requires a migration/import path.

| Purpose | Location |
|---|---|
| Configuration/instructions | `${XDG_CONFIG_HOME:-$HOME/.config}/swarm-code/` |
| Persistent user data and SQLite | `${XDG_DATA_HOME:-$HOME/.local/share}/swarm-code/` |
| Installed release versions | `${XDG_DATA_HOME:-$HOME/.local/share}/swarm-code/runtime/versions/V/` |
| Current release pointer | `${XDG_DATA_HOME:-$HOME/.local/share}/swarm-code/runtime/current` |
| Logs, crash reports, install receipt, rollback metadata | `${XDG_STATE_HOME:-$HOME/.local/state}/swarm-code/` |
| Disposable downloads/render caches | `${XDG_CACHE_HOME:-$HOME/.cache}/swarm-code/` |
| Sockets/locks for a live login session | `${XDG_RUNTIME_DIR}/swarm-code/`, with a verified owner/mode fallback if unset |
| User launcher | `${XDG_BIN_HOME:-$HOME/.local/bin}/swarm-code` as a convention |

The XDG specification does **not** define `XDG_BIN_HOME`; `~/.local/bin` is convention, so the installer must explain PATH handling. All XDG values used must be absolute. Runtime directories must be user-owned, mode 0700, and not susceptible to symlink/ownership attacks.

Keep runtime files and user data in distinct subtrees even though both live under XDG data. Uninstalling binaries must never accidentally delete the SQLite database.

### Atomic install/update model

- Acquire an interprocess install lock.
- Resolve and verify the desired artifact before touching the active version.
- Extract into a same-filesystem staging directory.
- Run artifact self-checks from staging without opening the user's real database.
- Atomically rename staging to an immutable version directory.
- Atomically switch `current` and the launcher.
- Retain at least the previous known-good runtime plus its receipt.
- Record installation provenance (`direct`, `homebrew`, `deb`, etc.). A package-managed install must delegate update/uninstall to that package manager; do not let the app self-update a Homebrew keg.

Provide `swarm-code update`, `swarm-code update --version V`, `swarm-code rollback`, and `swarm-code uninstall` only for direct installs. `uninstall` removes launcher, runtime versions, caches, and generated completions but preserves config/data/state by default. A separately confirmed `--purge` may remove user data and credential references.

Runtime rollback and data rollback are different. Before any schema-changing upgrade, create the required verified, independently restorable mode-0600 SQLite backup plus manifest and quarantine changed legacy data. Migrations should be forward-compatible across at least the retained runtime window. If an old runtime cannot open the migrated schema, `rollback` must say so rather than silently restoring or corrupting user data.

Offer an offline installation mode that accepts a local artifact, checksum/signature/attestation bundle, and version manifest. After installation, no extraction-time or first-run network call may be needed. A Burrito experiment must prove the same property and define whether its extracted payload is durable runtime or disposable cache.

### Shell completion

The executable should generate deterministic Bash, Zsh, and Fish completions for its exact version. Homebrew should install them using its standard completion helpers. The direct installer may place them in standard user locations only where discovery is reliable; otherwise expose `swarm-code completion <shell>` and an explicit `completion install` command. Do not append arbitrary `source` lines to shell startup files without opt-in. Completion generation and `--help` must work offline and without launching the full engine/database.

## CI release matrix and gates

Do not cross-build the production matrix merely because Burrito can. Build each artifact on its native CPU/OS baseline; this removes a large class of ERTS, NIF, linker, and code-signing uncertainty. Current GitHub-hosted runners list Ubuntu 22.04 arm64/x64 and macOS arm64/Intel labels, so native jobs are practical.

### Build jobs

| Job | Runner/baseline | Required outputs/gates |
|---|---|---|
| Linux x86_64 | pinned Ubuntu 22.04 x64 | Mix release, native Exqlite, ELF/glibc/link audit, archive, min-OS smoke |
| Linux arm64 | pinned Ubuntu 22.04 arm64 | same on native arm64 |
| macOS arm64 | pinned native arm64 macOS | deployment target, native Exqlite, nested signing, notarization, quarantine smoke |
| macOS Intel | pinned Intel macOS | same on native x86_64 |

Do not use `*-latest` for release compatibility baselines. Pin OTP and Elixir versions, verify downloaded toolchains, preserve `mix.lock`, and include compiler/SDK versions in provenance.

### Artifact acceptance tests

Every final, packaged artifact—not merely the source tree—must pass:

- architecture and `--version` identity
- startup with network denied and with empty XDG directories
- TUI launch in a real PTY; resize, Unicode and ASCII fallback, color modes, suspend/resume, Ctrl-C, SIGTERM, and clean exit
- non-TTY behavior for `--help`, `--version`, JSON/output modes, and completion generation
- SQLite create/migrate/write/read/reopen plus clean shutdown
- a representative engine run with fake/deterministic provider
- Git/project discovery and a command child-process lifecycle test
- no orphan BEAM, `epmd`, MCP, shell, or agent processes after exit
- read-only/noexec/space-containing home and project path cases where supported
- install, upgrade from previous stable, failed-upgrade preservation, rollback, uninstall-preserves-data
- max disk footprint and first/second launch timing measurements
- linkage checks with no unexpected host libraries or missing NIF
- signing/notarization/quarantine checks on macOS

Test the Linux artifact on Ubuntu 22.04, 24.04, and 26.04 for both CPUs. Test macOS on the exact claimed minimum and current releases on both CPUs; add self-hosted or another provider where GitHub lacks the minimum image. A QEMU test can supplement but not replace native acceptance for release artifacts.

### Release coordinator

A separate, protected coordinator should download the four already-built artifacts by digest, verify every job/result, generate checksums and the combined release manifest/SBOM material, attest each final artifact, upload everything to a draft release, exercise installer selection against the draft, and publish once. Enable GitHub release immutability. Update the Homebrew tap only after the immutable release is public, with exact URLs and SHA-256 values.

## Recommended phased distribution

### Phase 0 — packaging contract and native spike

- Confirm runtime-only versus full Elixir toolchain, Git prerequisite, minimum OSes, and Apple credentials.
- Create a CLI-only Mix release profile excluding desktop/wx/DBus.
- Produce and inspect four native archives with ERTS and Exqlite.
- Prove offline boot, PTY behavior, SQLite migration, child cleanup, and macOS hardened-runtime signing.
- Establish artifact names, manifest schema, XDG layout, and migration/rollback compatibility policy.

**Exit gate:** all four artifacts run on minimum systems with no Erlang/Elixir installed and no first-run download.

### Phase 1 — beta source of truth and direct install

- Publish draft/immutable GitHub prereleases with checksums, licenses, SBOM, provenance, and manual verification.
- Add the per-user direct installer, atomic version layout, install receipt, uninstall, pinned-version install, and offline local-artifact path.
- Dogfood upgrade and rollback across at least two real versions.

**Exit gate:** failed/cancelled/concurrent installs never damage the current runtime or user database.

### Phase 2 — macOS/Homebrew production convenience

- Complete Developer ID signing and notarization for both Mac CPUs.
- Publish the Homebrew tap using the same artifacts and completions.
- Keep the direct path available on macOS and primary on Ubuntu.
- Optionally add a stapled `.pkg` only if offline Gatekeeper or managed-fleet installation is required.

**Exit gate:** clean quarantined Mac installs have no bypass instructions and Homebrew upgrade/uninstall behave as documented.

### Phase 3 — Burrito single-file experiment

Build Burrito 1.6 artifacts in a separate branch/workflow and compare them against the exact acceptance fixture, not against aesthetic preference. Required go/no-go evidence:

- identical functional output and database behavior
- first-launch extraction location, locking, permissions, disk use, cancellation recovery, and cleanup
- no conflict between Burrito's old-payload removal and SwarmCode rollback
- all NIFs/helpers correct on four targets
- final-wrapper and extracted-payload signing/notarization proven on both Mac CPUs
- update does not mutate a running signed inode
- startup and package-size impact acceptable

Adopt Burrito only if the literal one-file property has a demonstrated user value and every gate passes. The existing archive channels should remain as recovery artifacts.

### Phase 4 — optional ecosystem packages

Based on demand, add signed `.deb`/apt, Snap classic, Nix, or an enterprise `.pkg`. Each channel should consume the canonical release artifacts or reproducibly rebuild the same source, record its provenance, and own its own update/uninstall behavior. Do not launch all channels before the core updater, compatibility matrix, and support burden are stable.

## Top risks

1. **Scope ambiguity:** bundled BEAM is not bundled Git/gh/MCP runtimes, and runtime-only Elixir is not a general Elixir toolchain.
2. **False portability:** `include_erts` does not erase target triple, glibc, OpenSSL, NIF, or terminal-library constraints.
3. **Desktop dependency leakage:** carrying elixir-desktop into the TUI would turn a small CLI native surface into wx/GTK/GStreamer packaging.
4. **macOS security late in the project:** hardened runtime/JIT entitlements and signing every nested Mach-O must be proven early.
5. **Updater/data coupling:** binary rollback can be unsafe after irreversible SQLite migrations.
6. **Bootstrap trust:** checksumming an artifact does not retroactively authenticate a piped installer fetched from a compromised channel.
7. **Overusing cross-compilation:** Burrito/Zig convenience does not replace native artifact tests.
8. **PATH claims:** a child no-root installer cannot modify the current parent shell environment.

## Authoritative/current sources

Accessed 2026-09-01 unless noted.

- Elixir Mix releases: self-contained release, `include_erts` default/recommended, target-triple and native/OpenSSL requirements, and lack of general official cross-compilation: <https://hexdocs.pm/mix/Mix.Tasks.Release.html>
- Burrito 1.6 documentation/readme: self-extracting BEAM/ERTS/NIF payload, targets, runtime extraction, maintenance behavior, experimental disclaimer, and supported target list: <https://burrito.hexdocs.pm> and <https://github.com/burrito-elixir/burrito>. Hex reports 1.6.0 published 2026-07-24: <https://hex.pm/packages/burrito>.
- Bakeware archive status/readme and releases: <https://github.com/bake-bake-bake/bakeware>, <https://hex.pm/packages/bakeware>, and repository API metadata <https://api.github.com/repos/bake-bake-bake/bakeware>.
- Exqlite configuration and current native release assets: <https://hexdocs.pm/exqlite>, <https://github.com/elixir-sqlite/exqlite>, and <https://github.com/elixir-sqlite/exqlite/releases>.
- Erlang/OTP build/install options, OpenSSL linking, platforms, and releases: <https://www.erlang.org/doc/system/install.html>.
- XDG Base Directory Specification 0.8: <https://specifications.freedesktop.org/basedir/latest/>.
- Homebrew checksum requirements, architecture/OS DSL, support tiers, Linux behavior, upgrade/uninstall: <https://docs.brew.sh/Checksum-Requirements>, <https://docs.brew.sh/Formula-Cookbook>, <https://docs.brew.sh/Cask-Cookbook>, <https://docs.brew.sh/Support-Tiers>, <https://docs.brew.sh/Homebrew-on-Linux>, and <https://docs.brew.sh/FAQ>.
- Apple notarization workflow, accepted containers, ZIP/standalone ticket stapling limitation: <https://developer.apple.com/documentation/security/customizing-the-notarization-workflow>.
- Apple hardened runtime and JIT entitlement: <https://developer.apple.com/documentation/security/hardened-runtime> and <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit>.
- Apple atomic replacement warning for signed code: <https://developer.apple.com/documentation/security/updating-mac-software>.
- GitHub artifact attestations/Sigstore and SBOM attestations: <https://docs.github.com/en/actions/concepts/security/artifact-attestations> and <https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations>.
- GitHub offline attestation verification: <https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline>.
- GitHub immutable releases and release verification: <https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases> and <https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity>.
- Current GitHub-hosted native runner labels: <https://docs.github.com/actions/reference/runners/github-hosted-runners>.
- Ubuntu package baselines: Jammy libc6 2.35 and Noble libc6 2.39: <https://packages.ubuntu.com/jammy/libc6> and <https://packages.ubuntu.com/noble/libc6>.
- Ubuntu lifecycle: <https://ubuntu.com/about/release-cycle>.
- glibc compatibility rationale for building on the oldest supported system: <https://developers.redhat.com/blog/2019/08/01/how-the-gnu-c-library-handles-backward-compatibility>.
- EEF Security WG CycloneDX generator for Mix/OTP/Elixir: <https://hexdocs.pm/sbom> and <https://github.com/erlef/mix_sbom>.
