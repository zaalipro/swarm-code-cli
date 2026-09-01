# SwarmCode CLI Foundation Milestone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the reviewable safety foundation for the standalone umbrella: reproducible governance and provenance, canonical private platform paths and process identity, an OS-enforced cross-application SQLite lease, a fail-closed schema/backup migration gate, and a bounded typed length-prefixed JSON protocol.

**Architecture:** `swarm_code_core` owns cross-client types and bounded wire encoding; `swarm_code_daemon` owns paths, identity, lease, schema inspection, backup, and migration admission; `swarm_code_cli` remains a dependency-light client shell. The milestone never starts the canonical Repo: it proves every pre-Repo gate in isolation and composes them in `SwarmCode.Daemon.FoundationGate` so later supervision can place it before Repo, Bootstrap, scheduler, MCP, and IPC admission.

**Tech Stack:** Erlang/OTP 28.4.2, Elixir 1.18.4-otp-28, Rust 1.97.1 (pinned now for later native spikes), Ecto SQL 3.14.x, ecto_sqlite3 0.24.x, Exqlite 0.39.x, SQLite 3.53.3 bundled by Exqlite, Jason 1.4.x, ExUnit.

**Spec:** `docs/superpowers/specs/2026-09-01-swarm-code-cli-design.md` and the reciprocal desktop contract at `/Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md`.

## Global Constraints

- Target macOS 14+ and Ubuntu 22.04+, arm64 and x86_64; do not enable Erlang distribution, EPMD, HTTP, Phoenix, LiveView, Desktop, wx, or TCP.
- Production macOS data is `~/Library/Application Support/SwarmCode/swarm_code.db`; production Ubuntu data is `${XDG_DATA_HOME:-$HOME/.local/share}/swarm-code/swarm_code.db`; production ignores `DATABASE_PATH`.
- Process umask is `077`; private directories are `0700`; database sidecars, lease, owner record, socket metadata, backups, and manifests are `0600`.
- The lease is `instance_lease.db`, rollback-journal mode, busy timeout zero, and `BEGIN EXCLUSIVE`; no PID record and no `--force` option can grant ownership.
- The audit baseline is desktop commit `dbb8804b3d7293178e571fa7afdf6bd47d06a51c`; the owner authorized public extraction and modification on 2026-09-01; the repository records that authorization, MIT licensing, copyright, and NOTICE terms before copying source.
- SQLite must be at least 3.51.3; every connection used here enables foreign keys.
- The current desktop does not honor the lease. Tests and copy must state the residual post-detection race and must not claim safe simultaneous operation.
- Every mutation-capable schema action requires the live lease and a verified independent backup first. Unknown/incompatible databases remain byte-for-byte unchanged.
- IPC is four-byte unsigned big-endian length plus UTF-8 JSON, never ETF; maximum frame is 1,048,576 bytes, maximum JSON depth is 16, and maximum aggregate object/array entries is 8,192.
- Runtime text never creates atoms. Known wire strings are converted only by closed function clauses.
- Use focused RED/GREEN cycles. End each task with its listed focused suite and a commit; end the milestone with `mix precommit`.

## Locked file map

```text
.formatter.exs                              umbrella formatting inputs
.gitignore                                  build/test artifacts only
.tool-versions                              build toolchain pins
config/config.exs                           shared compile-time config
config/runtime.exs                          no production DATABASE_PATH lookup
mix.exs                                     umbrella aliases and release-free root
governance/source-policy.json               truthful extraction authorization state
provenance/extracted-files.json             machine-readable copied-source ledger
apps/swarm_code_core/lib/swarm_code/          protocol types/codec and governance verifier
apps/swarm_code_core/test/swarm_code/          protocol/governance tests
apps/swarm_code_daemon/lib/swarm_code/         path, identity, lease, schema, backup gates
apps/swarm_code_daemon/priv/schema/            signed-in-release compatibility metadata
apps/swarm_code_daemon/test/swarm_code/         unit/integration/OS-process tests
apps/swarm_code_cli/lib/swarm_code_cli.ex    client application identity only
rel/env.sh.eex                              release-side `umask 077`
```

No extracted desktop implementation is added in this milestone. Migration names and hashes are recorded as authorized compatibility metadata; later copied/adapted source must be entered in the provenance ledger before commit. The compatibility manifest contains only file names, hashes, migration versions, and normalized schema hashes; that metadata is independently verifiable and does not execute upstream source.

---

### Task 1: Create the reproducible umbrella and dependency boundary

**Files:**
- Create: `LICENSE`, `NOTICE`, `SOURCE_AUTHORIZATION.md`
- Create: `.formatter.exs`, `.gitignore`, `.tool-versions`, `mix.exs`, `config/config.exs`, `config/runtime.exs`, `rel/env.sh.eex`
- Create: `apps/swarm_code_core/mix.exs`, `apps/swarm_code_core/lib/swarm_code_core.ex`, `apps/swarm_code_core/test/test_helper.exs`
- Create: `apps/swarm_code_daemon/mix.exs`, `apps/swarm_code_daemon/lib/swarm_code_daemon.ex`, `apps/swarm_code_daemon/test/test_helper.exs`
- Create: `apps/swarm_code_cli/mix.exs`, `apps/swarm_code_cli/lib/swarm_code_cli.ex`, `apps/swarm_code_cli/test/test_helper.exs`
- Test: `apps/swarm_code_core/test/swarm_code_core/architecture_test.exs`

**Interfaces:**
- Produces umbrella applications `:swarm_code_core`, `:swarm_code_daemon`, and `:swarm_code_cli`.
- `swarm_code_daemon` depends on `swarm_code_core`; `swarm_code_cli` depends only on `swarm_code_core` in this milestone.
- `mix precommit` means format check, warnings-as-errors compile, unused-lock check, all tests, and provenance verification.
- Root source is MIT licensed with `Copyright (c) 2026 ZaaliPro`; `SOURCE_AUTHORIZATION.md` records the owner's 2026-09-01 instruction to build and publish this open-source CLI and to adapt the pinned SwarmCode source, tests, specs, migrations, and fixtures. Every extracted file still requires a provenance-ledger entry.

- [ ] **Step 1: Write the dependency-boundary test before the app files exist**

```elixir
defmodule SwarmCodeCore.ArchitectureTest do
  use ExUnit.Case, async: true

  @forbidden ~w(phoenix phoenix_live_view bandit desktop desktop_deployment wx)

  test "umbrella has only the three approved applications" do
    root = Path.expand("../../../..", __DIR__)

    assert root
           |> Path.join("apps/*/mix.exs")
           |> Path.wildcard()
           |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
           |> Enum.sort() == ~w(swarm_code_cli swarm_code_core swarm_code_daemon)
  end

  test "locked dependency graph excludes web and desktop runtimes" do
    lock = Path.expand("../../../../mix.lock", __DIR__) |> File.read!()
    Enum.each(@forbidden, fn name -> refute lock =~ ~s("#{name}":) end)
  end

  test "runtime config never reads DATABASE_PATH" do
    runtime = Path.expand("../../../../config/runtime.exs", __DIR__) |> File.read!()
    refute runtime =~ "DATABASE_PATH"
  end
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_core/test/swarm_code_core/architecture_test.exs`

Expected: Mix reports that no umbrella project exists.

- [ ] **Step 3: Create the umbrella and pins**

Create the standard unmodified MIT license text in `LICENSE`, headed
`MIT License` and `Copyright (c) 2026 ZaaliPro`. `NOTICE` identifies the
project as `SwarmCode CLI`, names the pinned upstream repository and commit,
and requires `provenance/extracted-files.json` to enumerate adapted files.
`SOURCE_AUTHORIZATION.md` records the date, the user's public/open-source
instruction in this thread, the authorized artifact classes above, MIT as the
chosen SPDX license, and ZaaliPro as copyright holder. Then use this root
`mix.exs`:

```elixir
defmodule SwarmCodeCLI.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0-dev",
      elixir: "~> 1.18.4",
      start_permanent: Mix.env() == :prod,
      deps: [],
      aliases: aliases()
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "test",
        "swarm_code.provenance.verify"
      ]
    ]
  end
end
```

Use these exact dependency lists:

```elixir
# apps/swarm_code_core/mix.exs
defp deps, do: [{:jason, "== 1.4.5"}]

# apps/swarm_code_daemon/mix.exs
defp deps do
  [
    {:swarm_code_core, in_umbrella: true},
    {:ecto_sql, "== 3.14.2"},
    {:ecto_sqlite3, "== 0.24.1"},
    {:exqlite, "== 0.39.0"},
    {:jason, "== 1.4.5"}
  ]
end

# apps/swarm_code_cli/mix.exs
defp deps, do: [{:swarm_code_core, in_umbrella: true}]
```

Each child `project/0` uses `version: "0.1.0-dev"`, `elixir: "~> 1.18.4"`, `build_path: "../../_build"`, `config_path: "../../config/config.exs"`, `deps_path: "../../deps"`, and `lockfile: "../../mix.lock"`. Each `application/0` returns only `[extra_applications: [:logger, :crypto]]`; no application starts canonical work yet. `.tool-versions` is:

```text
erlang 28.4.2
elixir 1.18.4-otp-28
rust 1.97.1
```

`config/runtime.exs` contains only `import Config` and a comment that explicit alternate database paths are parsed by recovery/development commands rather than environment lookup. `rel/env.sh.eex` is:

```sh
#!/bin/sh
umask 077
```

- [ ] **Step 4: Fetch, lock, format, and run GREEN**

Run: `mix deps.get && mix format && mix test apps/swarm_code_core/test/swarm_code_core/architecture_test.exs`

Expected: 3 tests pass; `mix.lock` contains Jason/Ecto/Exqlite and no forbidden dependency.

- [ ] **Step 5: Commit**

```bash
git add LICENSE NOTICE SOURCE_AUTHORIZATION.md .formatter.exs .gitignore .tool-versions mix.exs mix.lock config rel apps
git commit -m "build: create standalone CLI umbrella"
```

---

### Task 2: Make source rights and provenance executable gates

**Files:**
- Create: `governance/source-policy.json`
- Create: `provenance/extracted-files.json`
- Create: `apps/swarm_code_core/lib/swarm_code/governance/provenance.ex`
- Create: `apps/swarm_code_core/lib/mix/tasks/swarm_code.provenance.verify.ex`
- Test: `apps/swarm_code_core/test/swarm_code/governance/provenance_test.exs`

**Interfaces:**
- Produces `SwarmCode.Governance.Provenance.verify(root) :: :ok | {:error, [String.t()]}`.
- An extracted entry has string keys `destination`, `upstream_path`, `upstream_commit`, `sha256`, and `classification` (`source`, `test`, or `spec`).
- Authorization is valid only when the root authorization/license/NOTICE files exist and the policy records all four authorization booleans; an empty extracted ledger is valid before the first extraction.

- [ ] **Step 1: Write RED tests for the fail-closed policy**

```elixir
defmodule SwarmCode.Governance.ProvenanceTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Governance.Provenance

  test "pending authorization accepts an empty extraction ledger" do
    root = fixture_root!("pending", [])
    assert :ok = Provenance.verify(root)
  end

  test "pending authorization rejects copied source" do
    root = fixture_root!("pending", [entry("lib/copied.ex", String.duplicate("a", 64))])
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/copied.ex"), "copied")
    assert {:error, errors} = Provenance.verify(root)
    assert "source extraction is blocked while authorization is pending" in errors
  end

  test "authorized entries require exact destination hashes and pinned commit" do
    root = fixture_root!("authorized", [entry("lib/copied.ex", String.duplicate("0", 64))])
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/copied.ex"), "copied")
    assert {:error, errors} = Provenance.verify(root)
    assert Enum.any?(errors, &String.contains?(&1, "sha256 mismatch"))
  end

  defp entry(path, hash) do
    %{
      "destination" => path,
      "upstream_path" => "lib/swarm_code/example.ex",
      "upstream_commit" => "dbb8804b3d7293178e571fa7afdf6bd47d06a51c",
      "sha256" => hash,
      "classification" => "source"
    }
  end

  defp fixture_root!(status, entries) do
    root = Path.join(System.tmp_dir!(), "provenance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "governance"))
    File.mkdir_p!(Path.join(root, "provenance"))
    File.write!(Path.join(root, "governance/source-policy.json"), Jason.encode!(policy(status)))
    File.write!(Path.join(root, "provenance/extracted-files.json"), Jason.encode!(%{"version" => 1, "entries" => entries}))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp policy(status) do
    %{
      "version" => 1,
      "audit_baseline" => "dbb8804b3d7293178e571fa7afdf6bd47d06a51c",
      "authorization_status" => status,
      "public_source_copying_allowed" => status == "authorized",
      "copyright_terms_recorded" => status == "authorized",
      "license_terms_recorded" => status == "authorized",
      "notice_terms_recorded" => status == "authorized"
    }
  end
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_core/test/swarm_code/governance/provenance_test.exs`

Expected: compile failure because `SwarmCode.Governance.Provenance` does not exist.

- [ ] **Step 3: Implement strict string-key decoding and digest verification**

```elixir
defmodule SwarmCode.Governance.Provenance do
  @baseline "dbb8804b3d7293178e571fa7afdf6bd47d06a51c"
  @classifications ~w(source test spec)

  @spec verify(Path.t()) :: :ok | {:error, [String.t()]}
  def verify(root) do
    with {:ok, policy} <- read_json(Path.join(root, "governance/source-policy.json")),
         {:ok, ledger} <- read_json(Path.join(root, "provenance/extracted-files.json")) do
      errors = policy_errors(policy) ++ authorization_file_errors(root, policy) ++ ledger_errors(root, policy, ledger)
      if errors == [], do: :ok, else: {:error, errors}
    else
      {:error, message} -> {:error, [message]}
    end
  end

  defp policy_errors(policy) do
    []
    |> add(policy["version"] != 1, "source policy version must be 1")
    |> add(policy["audit_baseline"] != @baseline, "audit baseline is not pinned")
    |> add(policy["authorization_status"] not in ~w(pending authorized clean_room), "invalid authorization status")
    |> add(policy["authorization_status"] == "authorized" and
      not Enum.all?(~w(public_source_copying_allowed copyright_terms_recorded license_terms_recorded notice_terms_recorded), &policy[&1]),
      "authorized extraction requires copying, copyright, license, and NOTICE records")
  end

  defp authorization_file_errors(root, %{"authorization_status" => "authorized"}) do
    for file <- ~w(LICENSE NOTICE SOURCE_AUTHORIZATION.md),
        not File.regular?(Path.join(root, file)),
        do: "authorized extraction requires root #{file}"
  end

  defp authorization_file_errors(_root, _policy), do: []

  defp ledger_errors(root, policy, %{"version" => 1, "entries" => entries}) when is_list(entries) do
    pending =
      if policy["authorization_status"] == "pending" and entries != [],
        do: ["source extraction is blocked while authorization is pending"],
        else: []

    pending ++ Enum.flat_map(entries, &entry_errors(root, &1))
  end

  defp ledger_errors(_root, _policy, _ledger), do: ["extracted-files ledger has an invalid shape"]

  defp entry_errors(root, entry) do
    destination = entry["destination"]
    path = if is_binary(destination), do: Path.expand(destination, root), else: root
    confined? = is_binary(destination) and Path.relative_to(path, root) != path and not String.starts_with?(destination, "../")
    actual = if confined? and File.regular?(path), do: path |> File.read!() |> sha256(), else: nil

    []
    |> add(not confined?, "unconfined provenance destination")
    |> add(entry["upstream_commit"] != @baseline, "entry is not pinned to the audit baseline")
    |> add(entry["classification"] not in @classifications, "invalid provenance classification")
    |> add(actual == nil, "provenance destination is missing or not regular")
    |> add(actual != nil and actual != entry["sha256"], "sha256 mismatch for #{destination}")
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path), {:ok, value} <- Jason.decode(bytes) do
      {:ok, value}
    else
      _ -> {:error, "cannot read valid JSON from #{path}"}
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp add(errors, true, message), do: errors ++ [message]
  defp add(errors, false, _message), do: errors
end
```

The Mix task calls `verify(File.cwd!())`, prints `provenance verified` on `:ok`, and raises one newline-joined error on failure.

Commit these truthful initial records:

```json
{"version":1,"audit_baseline":"dbb8804b3d7293178e571fa7afdf6bd47d06a51c","authorization_status":"authorized","public_source_copying_allowed":true,"copyright_terms_recorded":true,"license_terms_recorded":true,"notice_terms_recorded":true,"copyright_holder":"ZaaliPro","spdx_license":"MIT","authorization_date":"2026-09-01"}
```

```json
{"version":1,"entries":[]}
```

- [ ] **Step 4: Run GREEN**

Run: `mix test apps/swarm_code_core/test/swarm_code/governance/provenance_test.exs && mix swarm_code.provenance.verify`

Expected: 3 tests pass and the task prints `provenance verified`.

- [ ] **Step 5: Commit**

```bash
git add governance provenance apps/swarm_code_core
git commit -m "build: enforce source provenance policy"
```

---

### Task 3: Resolve and harden canonical paths and process identity

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/path_set.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/paths.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/private_directory.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/process_identity.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/paths_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/private_directory_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/process_identity_test.exs`

**Interfaces:**
- `Paths.resolve(keyword()) :: {:ok, PathSet.t()} | {:error, :unsupported_platform | :relative_xdg_path | :alternate_database_forbidden}`.
- Options are trusted atoms selected by boot code: `platform: :macos | :linux`, `mode: :production | :development | :test | :recovery`, `home: Path.t()`, `env: %{optional(String.t()) => String.t()}`, and optional `database_path: Path.t()`.
- `PrivateDirectory.ensure(Path.t(), uid) :: :ok | {:error, {:unsafe_private_directory, Path.t(), atom()}}` creates/chmods the leaf to `0700`, rejects symlinks and wrong ownership, and re-lstats after mutation.
- `ProcessIdentity.current(keyword()) :: {:ok, ProcessIdentity.t()} | {:error, term()}`; the injectable `read_file` and `command` functions exist only as explicit function options, never runtime-selected modules.

- [ ] **Step 1: Write RED path tests**

```elixir
defmodule SwarmCode.Daemon.Platform.PathsTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Daemon.Platform.Paths

  test "macOS shares the desktop database and ignores DATABASE_PATH in production" do
    home = "/Users/alice"
    assert {:ok, paths} = Paths.resolve(platform: :macos, mode: :production, home: home,
      env: %{"DATABASE_PATH" => "/tmp/attacker.db", "TMPDIR" => "/private/tmp/alice"})
    assert paths.database == "/Users/alice/Library/Application Support/SwarmCode/swarm_code.db"
    assert paths.lease == "/Users/alice/Library/Application Support/SwarmCode/instance_lease.db"
    assert paths.owner_record == "/Users/alice/Library/Application Support/SwarmCode/instance_owner.json"
    assert paths.runtime == "/private/tmp/alice/swarm-code"
  end

  test "Linux follows absolute XDG roots and has a private state fallback for runtime" do
    assert {:ok, paths} = Paths.resolve(platform: :linux, mode: :production, home: "/home/alice",
      env: %{"XDG_DATA_HOME" => "/data", "XDG_STATE_HOME" => "/state"})
    assert paths.database == "/data/swarm-code/swarm_code.db"
    assert paths.config == "/home/alice/.config/swarm-code"
    assert paths.state == "/state/swarm-code"
    assert paths.runtime == "/state/swarm-code/run"
    assert paths.socket == "/state/swarm-code/run/daemon.sock"
  end

  test "an alternate database is explicit and non-production only" do
    assert {:error, :alternate_database_forbidden} =
             Paths.resolve(platform: :linux, mode: :production, home: "/home/a", env: %{}, database_path: "/tmp/a.db")
    assert {:ok, paths} =
             Paths.resolve(platform: :linux, mode: :recovery, home: "/home/a", env: %{}, database_path: "/tmp/a.db")
    assert paths.database == "/tmp/a.db"
    assert paths.lease == "/tmp/instance_lease.db"
  end
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/platform/paths_test.exs`

Expected: compile failure because `Paths` does not exist.

- [ ] **Step 3: Implement the exact immutable path contract**

```elixir
defmodule SwarmCode.Daemon.Platform.PathSet do
  @enforce_keys [:platform, :data, :config, :state, :cache, :runtime, :database,
                 :lease, :owner_record, :socket, :socket_metadata, :backups]
  defstruct @enforce_keys
  @type t :: %__MODULE__{platform: :macos | :linux, data: Path.t(), config: Path.t(),
    state: Path.t(), cache: Path.t(), runtime: Path.t(), database: Path.t(), lease: Path.t(),
    owner_record: Path.t(), socket: Path.t(), socket_metadata: Path.t(), backups: Path.t()}
end
```

```elixir
defmodule SwarmCode.Daemon.Platform.Paths do
  alias SwarmCode.Daemon.Platform.PathSet
  @non_production [:development, :test, :recovery]

  def resolve(opts) do
    platform = Keyword.fetch!(opts, :platform)
    mode = Keyword.fetch!(opts, :mode)
    home = opts |> Keyword.fetch!(:home) |> Path.expand()
    env = Keyword.get(opts, :env, %{})

    with {:ok, roots} <- roots(platform, home, env),
         {:ok, database} <- database(Keyword.get(opts, :database_path), mode, roots.data) do
      data = if database == Path.join(roots.data, "swarm_code.db"), do: roots.data, else: Path.dirname(database)
      {:ok, struct!(PathSet, Map.merge(roots, %{
        platform: platform, data: data, database: database,
        lease: Path.join(data, "instance_lease.db"), owner_record: Path.join(data, "instance_owner.json"),
        socket: Path.join(roots.runtime, "daemon.sock"),
        socket_metadata: Path.join(roots.runtime, "daemon.json"), backups: Path.join(data, "backups")
      }))}
    end
  end

  defp roots(:macos, home, env) do
    data = Path.join([home, "Library", "Application Support", "SwarmCode"])
    runtime_base = absolute_or(Map.get(env, "TMPDIR"), Path.join([home, "Library", "Caches"]))
    {:ok, %{data: data, config: Path.join(data, "CLI"), state: Path.join([home, "Library", "Logs", "SwarmCode"]),
      cache: Path.join([home, "Library", "Caches", "SwarmCode", "CLI"]), runtime: Path.join(runtime_base, "swarm-code")}}
  end

  defp roots(:linux, home, env) do
    data = xdg(env, "XDG_DATA_HOME", Path.join([home, ".local", "share"]))
    config = xdg(env, "XDG_CONFIG_HOME", Path.join(home, ".config"))
    state = xdg(env, "XDG_STATE_HOME", Path.join([home, ".local", "state"]))
    cache = xdg(env, "XDG_CACHE_HOME", Path.join(home, ".cache"))
    app_state = Path.join(state, "swarm-code")
    runtime = case Map.get(env, "XDG_RUNTIME_DIR") do
      value when is_binary(value) and value != "" -> if Path.type(value) == :absolute, do: Path.join(value, "swarm-code"), else: Path.join(app_state, "run")
      _ -> Path.join(app_state, "run")
    end
    {:ok, %{data: Path.join(data, "swarm-code"), config: Path.join(config, "swarm-code"),
      state: app_state, cache: Path.join(cache, "swarm-code"), runtime: runtime}}
  end

  defp roots(_, _, _), do: {:error, :unsupported_platform}
  defp database(nil, _mode, data), do: {:ok, Path.join(data, "swarm_code.db")}
  defp database(path, mode, _data) when mode in @non_production, do: {:ok, Path.expand(path)}
  defp database(_path, _mode, _data), do: {:error, :alternate_database_forbidden}
  defp xdg(env, key, fallback), do: absolute_or(Map.get(env, key), fallback)
  defp absolute_or(value, fallback) when is_binary(value) and value != "", do: if(Path.type(value) == :absolute, do: Path.expand(value), else: fallback)
  defp absolute_or(_, fallback), do: fallback
end
```

- [ ] **Step 4: Add real filesystem and parser tests, then implement them**

The private-directory test creates a new temp leaf, asserts `Bitwise.band(File.stat!(leaf).mode, 0o777) == 0o700`, replaces it with a symlink, and expects `{:error, {:unsafe_private_directory, ^leaf, :symlink}}`. The implementation must use `File.lstat/1` before and after `File.mkdir/1`/`File.chmod/2`, compare `stat.uid` to the supplied uid, and never follow a symlink.

The identity parser test is exact and contains no OS timing:

```elixir
test "Linux identity uses proc start ticks and boot id" do
  stat = "731 (beam.smp) S " <> Enum.join(List.duplicate("0", 18), " ") <> " 998877 0 0"
  assert {:ok, identity} = ProcessIdentity.from_linux(502, 731, stat, " boot-uuid\n")
  assert identity == %ProcessIdentity{uid: 502, pid: 731,
    process_start_id: "linux-proc-start:998877", boot_id: "boot-uuid"}
end

test "Darwin identity normalizes fixed helper output" do
  assert {:ok, identity} = ProcessIdentity.from_darwin(502, 731,
    "2026-09-01T10:11:12.123456Z\n", "2026-08-20T07:00:00Z\n")
  assert identity.process_start_id == "darwin-proc-start:2026-09-01T10:11:12.123456Z"
  assert identity.boot_id == "darwin-boot:2026-08-20T07:00:00Z"
end
```

`ProcessIdentity.current/1` obtains UID from fixed `/usr/bin/id -u`, PID from `System.pid/0`, Linux data from `/proc/self/stat` and `/proc/sys/kernel/random/boot_id`, and Darwin timestamps from the bundled platform helper interface. Until the signed helper lands, production Darwin returns `{:error, :macos_platform_helper_unavailable}` rather than substituting `ps` process-name heuristics; tests and OS lease probes pass an already constructed identity.

- [ ] **Step 5: Run GREEN**

Run: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/platform`

Expected: all path, mode, symlink, Linux parser, and Darwin parser tests pass with no warnings.

- [ ] **Step 6: Commit**

```bash
git add apps/swarm_code_daemon
git commit -m "feat: define private platform paths and identity"
```

---

### Task 4: Implement atomic owner records and the Exqlite cross-app lease

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/startup_error.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/files/atomic_replace.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease/owner_record.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/files/atomic_replace_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs`

**Interfaces:**
- `AtomicReplace.write(path, iodata, mode: 0o600) :: :ok | {:error, term()}` uses same-directory exclusive temp creation, file fsync, rename, directory fsync, and cleanup on every exit.
- `CrossAppLease.start_link(keyword()) :: GenServer.on_start()` holds the Exqlite connection for its lifetime.
- Required options: `lease_path`, `owner_path`, `identity`, `database_fingerprint`, `schema_contract`, `socket_path`, `app_version`, and optional `name`.
- `CrossAppLease.owner(server) :: OwnerRecord.t()` and `CrossAppLease.assert_held(server) :: :ok` are the only later gate inputs.
- Contention returns `%StartupError{code: :data_lease_held, retryable: true, action: "Stop the owning runtime; never delete or force-unlock the lease."}`.

- [ ] **Step 1: Write RED behavioral tests**

```elixir
defmodule SwarmCode.Daemon.CrossAppLeaseTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.CrossAppLease
  alias SwarmCode.Daemon.Platform.ProcessIdentity

  setup do
    dir = Path.join(System.tmp_dir!(), "lease-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [lease_path: Path.join(dir, "instance_lease.db"), owner_path: Path.join(dir, "instance_owner.json"),
      identity: %ProcessIdentity{uid: File.stat!(dir).uid, pid: 123, process_start_id: "test:123", boot_id: "test-boot"},
      database_fingerprint: "sha256:test-db", schema_contract: %{epoch: 0, newest_migration: 20260926000000,
        manifest_sha256: "408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0"},
      socket_path: Path.join(dir, "daemon.sock"), app_version: "0.1.0-dev"]
    %{opts: opts}
  end

  test "one owner holds an exclusive rollback-journal lease", %{opts: opts} do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    assert :ok = CrossAppLease.assert_held(owner)
    assert File.stat!(opts[:lease_path]).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(opts[:owner_path]).mode |> Bitwise.band(0o777) == 0o600
    assert query_scalar(opts[:lease_path], "PRAGMA journal_mode") == "delete"

    assert {:error, %SwarmCode.Daemon.StartupError{code: :data_lease_held}} =
             CrossAppLease.start_link(Keyword.put(opts, :identity, %{opts[:identity] | pid: 124}))

    GenServer.stop(owner)
    refute File.exists?(opts[:owner_path])
    assert {:ok, next_owner} = CrossAppLease.start_link(opts)
    GenServer.stop(next_owner)
  end
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs`

Expected: compile failure because the lease modules do not exist.

- [ ] **Step 3: Implement atomic replacement before owner-record writes**

```elixir
defmodule SwarmCode.Daemon.Files.AtomicReplace do
  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write(path, contents, opts \\ []) do
    mode = Keyword.get(opts, :mode, 0o600)
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temp = Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp.#{nonce}")

    result = with {:ok, io} <- File.open(temp, [:write, :binary, :exclusive]),
      :ok <- File.chmod(temp, mode), :ok <- IO.binwrite(io, contents), :ok <- :file.sync(io),
      :ok <- File.close(io), :ok <- File.rename(temp, path), :ok <- sync_directory(Path.dirname(path)),
      do: :ok

    if result != :ok, do: File.rm(temp)
    result
  end

  defp sync_directory(path) do
    with {:ok, io} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do: :file.sync(io), after: :file.close(io)
    end
  end
end
```

Tests inject a write failure by passing invalid iodata, then assert that `Path.wildcard(Path.join(dir, ".owner.json.tmp.*")) == []` and the previous owner file is unchanged.

- [ ] **Step 4: Implement the lease critical path exactly**

```elixir
defmodule SwarmCode.Daemon.CrossAppLease do
  use GenServer
  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.{StartupError}
  alias SwarmCode.Daemon.CrossAppLease.OwnerRecord
  alias SwarmCode.Daemon.Files.AtomicReplace

  def child_spec(opts), do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]},
    restart: :temporary, significant: true}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def owner(server), do: GenServer.call(server, :owner)
  def assert_held(server), do: GenServer.call(server, :assert_held)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    with :ok <- secure_lease_file(opts[:lease_path], opts[:identity].uid),
         {:ok, conn} <- Sqlite3.open(opts[:lease_path], mode: :readwrite),
         :ok <- Sqlite3.set_busy_timeout(conn, 0),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=DELETE; PRAGMA foreign_keys=ON"),
         :ok <- acquire_exclusive(conn),
         record <- OwnerRecord.new(opts),
         :ok <- AtomicReplace.write(opts[:owner_path], [Jason.encode_to_iodata!(OwnerRecord.to_map(record)), "\n"], mode: 0o600) do
      {:ok, %{conn: conn, record: record, owner_path: opts[:owner_path]}}
    else
      {:error, :busy} -> {:stop, held_error(opts[:owner_path])}
      {:error, reason} -> {:stop, StartupError.new(:lease_failed, false, inspect(reason), "Inspect private path permissions and SQLite diagnostics.")}
    end
  end

  @impl true
  def handle_call(:owner, _from, state), do: {:reply, state.record, state}
  def handle_call(:assert_held, _from, state), do: {:reply, :ok, state}

  @impl true
  def terminate(_reason, state) do
    Sqlite3.execute(state.conn, "ROLLBACK")
    Sqlite3.close(state.conn)
    remove_if_same_nonce(state.owner_path, state.record.lease_nonce)
    :ok
  end

  defp acquire_exclusive(conn) do
    with {:ok, statement} <- Sqlite3.prepare(conn, "BEGIN EXCLUSIVE") do
      try do
        case Sqlite3.step(conn, statement) do
          :done -> :ok
          :busy -> {:error, :busy}
          {:error, reason} -> {:error, reason}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end
end
```

`secure_lease_file/2` creates an absent file with `File.open([:write, :exclusive, :binary])`, chmods `0600`, closes it, and for both new/existing cases lstat-verifies regular type, matching UID, and mode `0600` before Exqlite opens it. `OwnerRecord.new/1` creates a 32-byte random diagnostic `lease_nonce` and exact UTC ISO-8601 acquisition time; it emits only protocol version 1, product `cli-daemon`, app version, PID, process/boot identity, acquisition time, database fingerprint, schema epoch/newest migration/manifest hash, and socket path. It never emits the IPC nonce. `remove_if_same_nonce/2` reads at most 32 KiB and deletes only a matching record. Every partially opened Exqlite connection is closed in the error branch; implement this with a private `open_and_acquire/1` `try/after` helper rather than leaving the shortened snippet's connection cleanup implicit.

- [ ] **Step 5: Run GREEN**

Run: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/files/atomic_replace_test.exs apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs`

Expected: all tests pass; contention is immediate and owner removal is nonce-safe.

- [ ] **Step 6: Commit**

```bash
git add apps/swarm_code_daemon
git commit -m "feat: hold exclusive cross-application data lease"
```

---

### Task 5: Prove lease exclusion and crash release with real OS processes

**Files:**
- Create: `apps/swarm_code_daemon/test/support/lease_probe.exs`
- Create: `apps/swarm_code_daemon/test/support/os_process.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_os_test.exs`
- Modify: `apps/swarm_code_daemon/mix.exs` to use `elixirc_paths(:test) == ["lib", "test/support"]`

**Interfaces:**
- `SwarmCode.Daemon.Test.OSProcess.start_lease_probe!(opts) :: port()` starts a separate non-distributed BEAM using current compiled `-pa` paths.
- Probe line protocol is test-only: `READY <pid>`, input `GO`, output `ACQUIRED` or `HELD`, input `STOP`, then exit status 0.

- [ ] **Step 1: Write the OS-race RED test**

```elixir
defmodule SwarmCode.Daemon.CrossAppLeaseOSTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Test.OSProcess

  test "two fresh OS processes race; exactly one owns and SIGKILL releases" do
    dir = private_tmp!()
    canonical = Path.join(dir, "swarm_code.db")
    one = OSProcess.start_lease_probe!(dir)
    two = OSProcess.start_lease_probe!(dir)
    {pid_one, pid_two} = {OSProcess.await_ready!(one), OSProcess.await_ready!(two)}

    Port.command(one, "GO\n")
    Port.command(two, "GO\n")
    results = [{one, OSProcess.await_result!(one)}, {two, OSProcess.await_result!(two)}]
    assert Enum.sort(Enum.map(results, &elem(&1, 1))) == [:acquired, :held]
    refute File.exists?(canonical), "the losing startup must perform zero canonical DB opens"

    {winner, :acquired} = Enum.find(results, &(elem(&1, 1) == :acquired))
    winner_os_pid = if winner == one, do: pid_one, else: pid_two
    {_output, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(winner_os_pid)], stderr_to_stdout: true)
    OSProcess.await_exit!(winner)

    next = OSProcess.start_lease_probe!(dir)
    OSProcess.await_ready!(next)
    Port.command(next, "GO\n")
    assert :acquired = OSProcess.await_result!(next)
    Port.command(next, "STOP\n")
    OSProcess.await_exit!(next)
    File.rm_rf!(dir)
  end
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_os_test.exs`

Expected: compile failure because `OSProcess` does not exist.

- [ ] **Step 3: Implement synchronized probes without sleeps or liveness polling**

`lease_probe.exs` starts `:crypto`, `:jason`, and `:exqlite`; decodes its one base64url-encoded JSON argument with string keys; prints `READY #{System.pid()}`; blocks on `IO.gets("")`; calls `CrossAppLease.start_link/1`; prints exactly `ACQUIRED` or `HELD`; and, only when acquired, blocks for `STOP` before `GenServer.stop/1`. It never opens `swarm_code.db`.

`OSProcess.start_lease_probe!/1` uses `Port.open({:spawn_executable, System.find_executable("elixir")}, [:binary, :exit_status, {:line, 4096}, args: code_path_args ++ [probe_path, encoded_opts]])`. It sends every `{port, {:data, {:eol, line}}}` to the test process tagged with that exact port, and `await_*` uses `receive` with a 5,000 ms timeout. There is no `Process.sleep/1`, `Process.alive?/1`, PID-file inference, or restart on timeout.

Add a second test that sends `STOP` instead of SIGKILL, awaits exit, asserts `instance_owner.json` was removed, then proves a new process acquires. Add a third test that leaves the stale owner record after SIGKILL and proves it never grants or blocks ownership.

- [ ] **Step 4: Run GREEN repeatedly**

Run: `for i in 1 2 3 4 5; do mix test apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_os_test.exs --seed $i || exit 1; done`

Expected: each iteration passes; exactly one process reports `ACQUIRED`; no test uses timing sleeps.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_daemon
git commit -m "test: prove data lease across OS processes"
```

---

### Task 6: Embed and enforce the desktop migration/schema compatibility manifest

**Files:**
- Create: `apps/swarm_code_daemon/priv/schema/desktop-dbb8804b.json`
- Create: `apps/swarm_code_daemon/priv/schema/generate_manifest.exs`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/migration_manifest.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/sqlite_query.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/probe.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/gate.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/schema/migration_manifest_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/schema/gate_test.exs`
- Test fixture: `apps/swarm_code_daemon/test/fixtures/schema/exact_current.db` (generated, gitignored; test helper builds it deterministically)

**Interfaces:**
- `MigrationManifest.load!() :: MigrationManifest.t()` loads the application priv JSON and validates it before returning structs.
- Each `%MigrationManifest.Entry{version, filename, source_sha256, schema_sha256, additive_desktop_readable?}` uses integer version and lowercase 64-byte hex digests.
- `Probe.inspect(path) :: {:ok, Probe.t()} | {:error, StartupError.t()}` opens existing files `:readonly`, enables `query_only` and foreign keys, and returns application ID, ordered migration versions, normalized schema hash, SQLite version/source ID, quick check, and FK violations.
- `Gate.check(path, manifest, app_version) :: {:ok, %Decision{status: :ready | :migration_required | :new_database, pending: [Entry.t()]}} | {:error, StartupError.t()}`.
- No branch in `Gate.check/3` writes the database.

- [ ] **Step 1: Write RED tests for exact, prefix, unknown, gap, and schema drift**

```elixir
defmodule SwarmCode.Daemon.Schema.GateTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Daemon.Schema.{Gate, MigrationManifest}

  setup do
    manifest = MigrationManifest.load!()
    %{manifest: manifest, current: SchemaFixture.database!(:current)}
  end

  test "the audited desktop lineage is ready without mutation", %{manifest: manifest, current: db} do
    before = sha256_file(db)
    assert {:ok, decision} = Gate.check(db, manifest, "0.1.0-dev")
    assert decision.status == :ready
    assert decision.applied |> List.last() == 20260926000000
    assert sha256_file(db) == before
  end

  test "a supported exact prefix requests only its suffix", %{manifest: manifest} do
    db = SchemaFixture.database!({:prefix, 20260923000000})
    assert {:ok, %{status: :migration_required, pending: pending}} = Gate.check(db, manifest, "0.1.0-dev")
    assert Enum.map(pending, & &1.version) == [20260924000000, 20260925000000, 20260926000000]
  end

  test "unknown newer migration refuses without mutation", %{manifest: manifest, current: db} do
    SchemaFixture.insert_migration!(db, 20990101000000)
    before = sha256_file(db)
    assert {:error, %{code: :schema_incompatible}} = Gate.check(db, manifest, "0.1.0-dev")
    assert sha256_file(db) == before
  end

  test "known versions with a gap and a normalized-schema mismatch refuse", %{manifest: manifest} do
    gap = SchemaFixture.database!({:prefix, 20260924000000})
    SchemaFixture.delete_migration!(gap, 20260923000000)
    assert {:error, %{code: :schema_incompatible}} = Gate.check(gap, manifest, "0.1.0-dev")

    drift = SchemaFixture.database!(:current)
    SchemaFixture.exec!(drift, "CREATE TABLE injected(value TEXT)")
    assert {:error, %{code: :schema_incompatible}} = Gate.check(drift, manifest, "0.1.0-dev")
  end
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/schema`

Expected: missing `MigrationManifest`/`Gate` modules.

- [ ] **Step 3: Generate and commit the exact 43-entry metadata manifest**

`generate_manifest.exs` accepts exactly `--upstream PATH --commit COMMIT --output PATH`; rejects any commit other than `dbb8804b3d7293178e571fa7afdf6bd47d06a51c`; enumerates `priv/repo/migrations/[0-9]*.exs` using `git ls-tree`; reads bytes using `git show COMMIT:PATH`; hashes those bytes; applies one migration at a time only to a fresh `System.tmp_dir!/swarm-code-schema-manifest-<random>/fixture.db`; and computes the normalized hash after every prefix. It refuses if the source worktree is dirty, if there are not exactly 43 migrations, or if the final normalized hash is not `cb75e8448370fa9ca8c1f25969e1b491b035046e87f8b92374f5a1c704304db3`. It always removes the temporary directory.

Run once:

```bash
mix run --no-start apps/swarm_code_daemon/priv/schema/generate_manifest.exs -- \
  --upstream /Users/zaali/dev/swarm-code \
  --commit dbb8804b3d7293178e571fa7afdf6bd47d06a51c \
  --output apps/swarm_code_daemon/priv/schema/desktop-dbb8804b.json
```

The JSON top level is exactly:

```json
{
  "manifest_version": 1,
  "contract": "desktop-dbb8804b",
  "upstream_commit": "dbb8804b3d7293178e571fa7afdf6bd47d06a51c",
  "application_ids": [0],
  "data_epoch": 0,
  "minimum_reader": "0.1.0-dev",
  "minimum_writer": "0.1.0-dev",
  "sqlite_minimum": "3.51.3",
  "migration_set_sha256": "408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0",
  "legacy_handshake": "migration-prefix-plus-normalized-schema",
  "migrations": []
}
```

The generator replaces the shown empty array with all 43 records. It defines
`migration_set_sha256` as SHA-256 over, for each ordered migration,
`version <> NUL <> filename <> NUL <> source_sha256 <> LF`; this audited set
is `408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0`.
Verify first record version/file/source digest `20260820000001`,
`20260820000001_create_swarm_code_schema.exs`,
`7b85670338191af007a196d8b2bf4f88bde6511bddbfb9a5efc691a8c6606f44`;
verify last record `20260926000000`,
`20260926000000_supersede_on_edit.exs`,
`9343537359fd75470d78bf4d72da4de5180ceb0e3b39d379e6c1348bc5fa4128`,
schema digest `cb75e8448370fa9ca8c1f25969e1b491b035046e87f8b92374f5a1c704304db3`.
Every record sets `additive_desktop_readable` true because it belongs to the
audited desktop lineage; this does not authorize future CLI-only migrations.

- [ ] **Step 4: Implement strict manifest decoding and normalized schema probing**

`MigrationManifest.load!/0` decodes with string keys, checks exact required-key sets, strict increasing versions, filename/version agreement, digest format, supported application IDs, semantic version strings, final/migration-set sentinel digests, and 43 entries. It never calls `String.to_atom/1`.

`SqliteQuery.rows/3` owns prepare/bind/step/release in `try/after`. `Probe` computes the schema hash without ambiguous concatenation:

```elixir
rows = SqliteQuery.rows(conn, """
SELECT type, name, tbl_name, coalesce(sql, '')
FROM sqlite_schema
WHERE name NOT LIKE 'sqlite_%'
ORDER BY type, name
""", [])

schema_sha256 =
  rows
  |> Enum.flat_map(fn row -> Enum.map(row, fn value ->
    bytes = to_string(value)
    [Integer.to_string(byte_size(bytes)), ?:, bytes, ?\n]
  end) end)
  |> :crypto.hash(:sha256)
  |> Base.encode16(case: :lower)
```

`Gate.check/3` requires `quick_check == [["ok"]]`, zero FK rows, SQLite version >= 3.51.3, application ID in `[0]`, applied versions equal to an exact leading prefix (not merely a subset), and normalized hash equal to the schema hash recorded on that prefix. An absent file returns `:new_database`; a zero-byte or non-SQLite existing file is incompatible, not new.

- [ ] **Step 5: Run GREEN and prove the manifest is reproducible**

Run:

```bash
mix test apps/swarm_code_daemon/test/swarm_code/daemon/schema
tmp=$(mktemp)
mix run --no-start apps/swarm_code_daemon/priv/schema/generate_manifest.exs -- \
  --upstream /Users/zaali/dev/swarm-code --commit dbb8804b3d7293178e571fa7afdf6bd47d06a51c --output "$tmp"
cmp "$tmp" apps/swarm_code_daemon/priv/schema/desktop-dbb8804b.json
rm "$tmp"
```

Expected: tests pass and `cmp` is silent.

- [ ] **Step 6: Commit**

```bash
git add apps/swarm_code_daemon
git commit -m "feat: enforce shared schema compatibility manifest"
```

---

### Task 7: Create and independently verify a migration backup before admission

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/artifact.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/manifest.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/gate.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/backup/gate_test.exs`

**Interfaces:**
- `Backup.Gate.create(source_path, backup_dir, operation_id, lease, schema_decision, keyword()) :: {:ok, Artifact.t()} | {:error, StartupError.t()}`.
- `operation_id` is a validated UUID string; `lease` is the live CrossAppLease server; `schema_decision.status` must be `:migration_required`.
- `%Artifact{database, manifest, operation_id, source_sha256, backup_sha256, verified_at}` is returned only after independent restore verification and fsync.
- SQLite-engine `VACUUM main INTO ?` from a read-only source connection is used as the bounded consistent snapshot while the cross-runtime lease is held; a raw copy of a live WAL database is forbidden.

- [ ] **Step 1: Write the RED success and fault-injection tests**

```elixir
test "verified artifact contains every table count and an independently openable restore" do
  %{db: db, lease: lease, decision: decision, backup_dir: dir} = migration_fixture!()
  assert {:ok, artifact} = Gate.create(db, dir, "c608e2b2-441d-45fc-ae80-42199f63ddff", lease, decision,
    now: fn -> ~U[2026-09-01 12:00:00Z] end)
  assert File.stat!(artifact.database).mode |> Bitwise.band(0o777) == 0o600
  assert File.stat!(artifact.manifest).mode |> Bitwise.band(0o777) == 0o600
  manifest = artifact.manifest |> File.read!() |> Jason.decode!()
  assert manifest["quick_check"] == "ok"
  assert manifest["foreign_key_violations"] == []
  assert manifest["row_counts"] == SchemaFixture.row_counts(db)
  assert manifest["independent_restore"]["verified"] == true
  assert Probe.inspect(artifact.database).schema_sha256 == decision.schema_sha256
end

for point <- [:after_snapshot, :after_manifest, :after_restore_copy, :before_publish] do
  test "failure at #{point} leaves source unchanged and no published artifact" do
    %{db: db, lease: lease, decision: decision, backup_dir: dir} = migration_fixture!()
    before = files_digest(db)
    assert {:error, %{code: :backup_failed}} = Gate.create(db, dir,
      "c608e2b2-441d-45fc-ae80-42199f63ddff", lease, decision,
      fault: unquote(point))
    assert files_digest(db) == before
    assert Path.wildcard(Path.join(dir, "*")) == []
  end
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/backup/gate_test.exs`

Expected: missing backup modules.

- [ ] **Step 3: Implement snapshot, manifest, restore proof, and publication in that order**

The implementation must:

1. call `CrossAppLease.assert_held/1` before opening the source;
2. create the backup directory through `PrivateDirectory.ensure/2`;
3. use unpublished dot-prefixed paths containing the operation UUID;
4. open the source with `mode: :readonly`, set foreign keys and busy timeout, prepare `VACUUM main INTO ?`, bind the unpublished backup path, step to `:done`, and release/close in `after`;
5. chmod the snapshot `0600`, cold-open it read-only, run `quick_check`, `foreign_key_check`, ordered migrations, normalized schema hash, representative first/last-row reads where a table has rows, and a count for every non-SQLite table;
6. stream SHA-256 in 1 MiB chunks rather than `File.read!/1` for database files;
7. atomically write a `0600` JSON manifest with source main/WAL/SHM names, sizes and hashes; backup size/hash; application ID; schema hash; SQLite version/source ID; ordered migrations; all row counts; checks; UTC timestamp; app version; and operation ID;
8. chunk-copy the cold backup to a same-directory independent restore file, chmod/fsync it, reopen and rerun all checks/counts/hashes, then delete it;
9. fsync backup, manifest, and directory, atomically rename both unpublished files to final names, then fsync the directory again;
10. remove all unpublished/final outputs on every failure before publication. After publication, return the typed artifact and retain it.

Use this prepared statement (never interpolate the path):

```elixir
{:ok, statement} = Exqlite.Sqlite3.prepare(conn, "VACUUM main INTO ?")
try do
  :ok = Exqlite.Sqlite3.bind(statement, [staging_backup])
  :done = Exqlite.Sqlite3.step(conn, statement)
after
  Exqlite.Sqlite3.release(conn, statement)
end
```

The `fault:` option is accepted only when `Mix.env() == :test`; production raises on any supplied fault option. Add negative tests for no lease, wrong decision status, duplicate operation ID (returns the already verified identical artifact), corrupt source, disk permission failure, FK failure, and a manifest count mismatch.

- [ ] **Step 4: Run GREEN**

Run: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/backup/gate_test.exs`

Expected: success, idempotency, integrity, and all fault points pass; no temp files remain.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_daemon
git commit -m "feat: gate migrations on verified SQLite backup"
```

---

### Task 8: Define the closed, typed JSON envelope and structural limits

**Files:**
- Create: `apps/swarm_code_core/lib/swarm_code/protocol/error.ex`
- Create: `apps/swarm_code_core/lib/swarm_code/protocol/scope.ex`
- Create: `apps/swarm_code_core/lib/swarm_code/protocol/message.ex`
- Create: `apps/swarm_code_core/lib/swarm_code/protocol/json_limits.ex`
- Create: `apps/swarm_code_core/lib/swarm_code/protocol/envelope.ex`
- Test: `apps/swarm_code_core/test/swarm_code/protocol/envelope_test.exs`
- Test: `apps/swarm_code_core/test/swarm_code/protocol/json_limits_test.exs`

**Interfaces:**
- `%Message{version: 1, type:, request_id:, nonce:, scope:, sequence:, occurred_at:, body:}`.
- Closed `type` is `:hello | :hello_ok | :request | :response | :event | :error | :snapshot_required | :ping | :pong`.
- `%Scope{kind: :global | :project | :conversation | :run | :research | :workflow | :schedule, id: String.t() | nil, generation: non_neg_integer()}`.
- `Envelope.encode(Message.t()) :: {:ok, iodata()} | {:error, Error.t()}` returns JSON only, without a frame header.
- `Envelope.decode(binary()) :: {:ok, Message.t()} | {:error, Error.t()}` preserves body keys as strings.
- `JsonLimits.validate(binary(), max_depth: 16, max_entries: 8_192) :: :ok | {:error, Error.t()}` performs a string/escape-aware lexical preflight before Jason allocation, then an exact post-decode count.

- [ ] **Step 1: Write RED round-trip, shape, depth, and atom-safety tests**

```elixir
defmodule SwarmCode.Protocol.EnvelopeTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Protocol.{Envelope, Message, Scope}

  test "a typed event round-trips while runtime keys stay binaries" do
    message = %Message{version: 1, type: :event, request_id: nil,
      nonce: "7MEe1H2sfyDTvqPFUwR54awB9ZyiW9I9oXaBbmV5_sQ",
      scope: %Scope{kind: :run, id: "0198cda0-77c8-7d65-b7a4-f465638cc132", generation: 4},
      sequence: 91, occurred_at: "2026-09-01T12:34:56.123456Z",
      body: %{"event" => "assistant_text", "delta" => "exact bytes"}}
    assert {:ok, encoded} = Envelope.encode(message)
    assert {:ok, ^message} = encoded |> IO.iodata_to_binary() |> Envelope.decode()
  end

  test "unknown types and extra envelope fields are rejected without atom creation" do
    valid = %{"v" => 1, "type" => "type-#{System.unique_integer([:positive])}",
      "request_id" => nil, "nonce" => String.duplicate("a", 43), "scope" => nil,
      "sequence" => nil, "occurred_at" => nil, "body" => %{}}
    _ = Envelope.decode(Jason.encode!(valid))
    before = :erlang.system_info(:atom_count)
    Enum.each(1..1_000, fn n ->
      assert {:error, %{code: :unknown_message_type}} =
               Envelope.decode(Jason.encode!(%{valid | "type" => "untrusted-#{n}-#{:rand.uniform()}"}))
    end)
    assert :erlang.system_info(:atom_count) == before
    assert {:error, %{code: :invalid_envelope}} =
             Envelope.decode(Jason.encode!(Map.put(valid, "admin", true)))
  end

  test "event invariants require scope, sequence, and occurrence time" do
    invalid = %{"v" => 1, "type" => "event", "request_id" => nil,
      "nonce" => String.duplicate("a", 43), "scope" => nil, "sequence" => nil,
      "occurred_at" => nil, "body" => %{}}
    assert {:error, %{code: :invalid_envelope}} = Envelope.decode(Jason.encode!(invalid))
  end
end
```

```elixir
test "preflight rejects nesting and entry bombs before JSON decode" do
  assert {:error, %{code: :json_too_deep}} = JsonLimits.validate(String.duplicate("[", 17) <> String.duplicate("]", 17))
  bomb = "[" <> Enum.map_join(1..8_193, ",", fn _ -> "0" end) <> "]"
  assert {:error, %{code: :json_entry_limit}} = JsonLimits.validate(bomb)
  assert :ok = JsonLimits.validate(~s({"literal":"[[[[,,:,:]]]]","escaped":"\\\"{"}))
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_core/test/swarm_code/protocol/envelope_test.exs apps/swarm_code_core/test/swarm_code/protocol/json_limits_test.exs`

Expected: protocol modules are undefined.

- [ ] **Step 3: Implement structs and only closed string-to-atom clauses**

```elixir
defmodule SwarmCode.Protocol.Message do
  alias SwarmCode.Protocol.Scope
  @enforce_keys [:version, :type, :request_id, :nonce, :scope, :sequence, :occurred_at, :body]
  defstruct @enforce_keys
  @type message_type :: :hello | :hello_ok | :request | :response | :event | :error |
    :snapshot_required | :ping | :pong
  @type t :: %__MODULE__{version: 1, type: message_type(), request_id: String.t() | nil,
    nonce: String.t(), scope: Scope.t() | nil, sequence: non_neg_integer() | nil,
    occurred_at: String.t() | nil, body: %{optional(String.t()) => term()}}
end
```

`Envelope.decode/1` first enforces byte and structural limits, calls `Jason.decode/1` with default string keys, requires the exact key set `v,type,request_id,nonce,scope,sequence,occurred_at,body`, and maps types through clauses such as `defp type("event"), do: {:ok, :event}` plus a final `{:error, :unknown_message_type}`. Do the same for scope kinds. Validate nonce as exactly 43 base64url characters that decode to 32 bytes; request IDs/scope IDs as lowercase canonical UUID text; sequence/generation as nonnegative integers; occurrence time with `DateTime.from_iso8601/1`; body as a string-keyed map. `hello`, `hello_ok`, `request`, `response`, and `error` require request ID; `event` requires scope/sequence/time; `snapshot_required` requires scope; ping/pong do not require scope.

`JsonLimits` scans one byte at a time with state `{in_string?, escaped?, depth, entries}`. Outside strings, `{`/`[` increments depth and entries, `}`/`]` decrements, and `,`/`:` increments entries. It rejects negative/unclosed depth and unfinished strings as invalid JSON. After Jason decode, recursively count each map pair/list item and reject over 8,192; maps with any nonbinary key are invalid. This scan never constructs an atom.

- [ ] **Step 4: Run GREEN**

Run: `mix test apps/swarm_code_core/test/swarm_code/protocol/envelope_test.exs apps/swarm_code_core/test/swarm_code/protocol/json_limits_test.exs`

Expected: all protocol schema/limit/atom tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_core
git commit -m "feat: define bounded typed JSON protocol"
```

---

### Task 9: Add incremental four-byte framing without growing-binary concatenation

**Files:**
- Create: `apps/swarm_code_core/lib/swarm_code/protocol/chunk_buffer.ex`
- Create: `apps/swarm_code_core/lib/swarm_code/protocol/frame.ex`
- Create: `apps/swarm_code_core/lib/swarm_code/protocol/frame_decoder.ex`
- Test: `apps/swarm_code_core/test/swarm_code/protocol/chunk_buffer_test.exs`
- Test: `apps/swarm_code_core/test/swarm_code/protocol/frame_test.exs`

**Interfaces:**
- `Frame.encode(Message.t()) :: {:ok, iodata()} | {:error, Error.t()}` prepends unsigned 32-bit big-endian JSON byte length.
- `FrameDecoder.new(keyword()) :: FrameDecoder.t()`; default `max_frame_bytes: 1_048_576`, `max_frames_per_push: 64`.
- `FrameDecoder.push(decoder, binary()) :: {:ok, [Message.t()], decoder} | {:error, Error.t()}`.
- Decoder is terminal after any error; caller closes the socket. It never rescans previously consumed bytes and never appends to a growing binary.

- [ ] **Step 1: Write RED fragmentation/coalescing/limit tests**

```elixir
test "every split point and coalesced frames decode exactly once" do
  first = message("one")
  second = message("two")
  bytes = IO.iodata_to_binary([Frame.encode!(first), Frame.encode!(second)])

  Enum.each(0..byte_size(bytes), fn split ->
    <<left::binary-size(split), right::binary>> = bytes
    decoder = FrameDecoder.new()
    assert {:ok, left_messages, decoder} = FrameDecoder.push(decoder, left)
    assert {:ok, right_messages, decoder} = FrameDecoder.push(decoder, right)
    assert left_messages ++ right_messages == [first, second]
    assert decoder.buffered_bytes == 0
  end)
end

test "zero, oversized, malformed, and too-many frames fail closed" do
  assert {:error, %{code: :zero_length_frame}} = FrameDecoder.push(FrameDecoder.new(), <<0::32>>)
  assert {:error, %{code: :frame_too_large}} = FrameDecoder.push(FrameDecoder.new(max_frame_bytes: 8), <<9::32>>)
  assert {:error, %{code: :invalid_json}} = FrameDecoder.push(FrameDecoder.new(), <<1::32, ?{>>)
  ping = Frame.encode!(message("x"))
  assert {:error, %{code: :frame_count_limit}} =
           FrameDecoder.push(FrameDecoder.new(max_frames_per_push: 2), IO.iodata_to_binary([ping, ping, ping]))
end

test "one-byte delivery remains byte bounded" do
  bytes = Frame.encode!(message(String.duplicate("x", 100_000))) |> IO.iodata_to_binary()
  {messages, decoder} = Enum.reduce(:binary.bin_to_list(bytes), {[], FrameDecoder.new()}, fn byte, {out, decoder} ->
    assert {:ok, decoded, decoder} = FrameDecoder.push(decoder, <<byte>>)
    assert decoder.buffered_bytes <= 1_048_576
    {out ++ decoded, decoder}
  end)
  assert length(messages) == 1
  assert decoder.buffered_bytes == 0
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_core/test/swarm_code/protocol/frame_test.exs`

Expected: framing modules are undefined.

- [ ] **Step 3: Implement a queue-backed chunk buffer**

```elixir
defmodule SwarmCode.Protocol.ChunkBuffer do
  defstruct queue: :queue.new(), bytes: 0
  def new, do: %__MODULE__{}
  def put(buffer, <<>>), do: buffer
  def put(%__MODULE__{queue: q, bytes: n} = buffer, binary) when is_binary(binary),
    do: %{buffer | queue: :queue.in(binary, q), bytes: n + byte_size(binary)}

  def take(%__MODULE__{bytes: available}, wanted) when wanted > available, do: :more
  def take(buffer, wanted) when wanted >= 0 do
    {parts, queue} = take_queue(buffer.queue, wanted, [])
    {:ok, Enum.reverse(parts), %{buffer | queue: queue, bytes: buffer.bytes - wanted}}
  end

  defp take_queue(queue, 0, acc), do: {acc, queue}
  defp take_queue(queue, wanted, acc) do
    {{:value, chunk}, rest} = :queue.out(queue)
    if byte_size(chunk) <= wanted do
      take_queue(rest, wanted - byte_size(chunk), [chunk | acc])
    else
      <<head::binary-size(wanted), tail::binary>> = chunk
      {[head | acc], :queue.in_r(tail, rest)}
    end
  end
end
```

- [ ] **Step 4: Implement the phase machine**

`FrameDecoder` has `phase: :header | {:body, positive_integer}`, `buffer`, `buffered_bytes`, `max_frame_bytes`, and `max_frames_per_push`. `push/2` enqueues the new binary once, takes exactly four header bytes when available, decodes `<<length::unsigned-big-32>>`, rejects zero/oversize before accepting a body, and takes exactly length bytes. Only the completed body is converted once with `IO.iodata_to_binary/1` and passed to `Envelope.decode/1`. It loops until incomplete, preserving frame order; a 65th completed frame fails before returning a partial success. `Frame.encode/1` checks `byte_size(json) <= 1_048_576` and returns `[<<size::unsigned-big-32>>, json]`.

Do not implement the decoder as `state.buffer <> chunk`, recursive `binary_part` over an ever-growing transcript, or an end-appended list.

- [ ] **Step 5: Run GREEN plus randomized deterministic chunk schedules**

Add a seeded test that partitions 100 encoded messages with chunk sizes from `:rand.uniform(97)` and asserts exact output. Then run:

Run: `mix test apps/swarm_code_core/test/swarm_code/protocol --seed 73191`

Expected: all envelope, limits, chunk-buffer, fragmentation, coalescing, and randomized schedules pass.

- [ ] **Step 6: Commit**

```bash
git add apps/swarm_code_core
git commit -m "feat: stream length-prefixed JSON frames"
```

---

### Task 10: Compose the pre-Repo foundation gate and close the milestone

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/foundation_gate_test.exs`
- Create: `docs/foundation-safety.md`
- Modify: `README.md`

**Interfaces:**
- `FoundationGate.prepare(keyword()) :: {:ok, %FoundationGate.Ready{paths:, identity:, lease:, schema:, backup:}} | {:error, StartupError.t()}`.
- Exact order: resolve paths; harden private directories; obtain identity; macOS desktop detection callback before DB access; acquire lease; repeat detection; load/validate manifest; read-only schema gate; for `:migration_required`, create verified backup then return an explicit `:migration_implementation_not_installed` refusal in this pre-Repo milestone; for `:ready`, return the live lease. Any failure stops the lease before returning.
- The caller owns the returned lease and must stop Repo/work descendants before stopping it.

- [ ] **Step 1: Write the order-and-no-side-effect RED integration test**

```elixir
test "foundation orders detection, lease, schema and never starts Repo" do
  parent = self()
  fixture = exact_schema_fixture!()
  detector = fn -> send(parent, :detected); :none end
  assert {:ok, ready} = FoundationGate.prepare(test_opts(fixture, detector))
  assert_receive :detected
  assert_receive :detected
  assert :ok = CrossAppLease.assert_held(ready.lease)
  refute Process.whereis(SwarmCode.Repo)
  GenServer.stop(ready.lease)
end

test "desktop refusal happens before lease or canonical database access" do
  fixture = Path.join(private_tmp!(), "must-not-exist.db")
  detector = fn -> {:active, %{pid: 731, application: "SwarmCode"}} end
  assert {:error, %{code: :desktop_active}} = FoundationGate.prepare(test_opts(fixture, detector))
  refute File.exists?(fixture)
  refute File.exists?(Path.join(Path.dirname(fixture), "instance_lease.db"))
end

test "post-acquire desktop refusal releases the lease" do
  counter = :counters.new(1, [])
  detector = fn ->
    call = :counters.add(counter, 1, 1)
    if call == 1, do: :none, else: {:active, %{pid: 732, application: "SwarmCode"}}
  end
  opts = test_opts(exact_schema_fixture!(), detector)
  assert {:error, %{code: :desktop_active}} = FoundationGate.prepare(opts)
  assert {:ok, lease} = CrossAppLease.start_link(lease_opts(opts))
  GenServer.stop(lease)
end
```

- [ ] **Step 2: Run RED**

Run: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/foundation_gate_test.exs`

Expected: `FoundationGate` is missing.

- [ ] **Step 3: Implement the linear gate with one cleanup path**

Implement `prepare/1` as a `with` chain up to lease acquisition, then a `try ... catch` around post-acquisition checks whose `else` branch always `GenServer.stop(lease)`. Do not supervise Repo in this task. Tests inject deterministic detector/identity/clock functions; production macOS requires the signed bundle-identity detector and returns `:macos_platform_helper_unavailable` until that separate spike lands. Linux detector is `fn -> :none end`.

`docs/foundation-safety.md` must state verbatim:

> The current macOS desktop release does not acquire the shared SQLite lease. SwarmCode CLI detects an already-running desktop before and after acquiring its own lease, but the desktop can still start after the second check. Concurrent desktop/CLI operation is unsupported. Quit the desktop before starting the CLI daemon, and stop the CLI daemon before reopening the desktop. There is no force-unlock option.

README links the approved design and this safety note, says the dated source authorization and MIT terms are recorded, and describes this milestone as pre-Repo infrastructure rather than a usable CLI release.

- [ ] **Step 4: Run all focused milestone gates**

```bash
mix test apps/swarm_code_core/test/swarm_code/governance \
  apps/swarm_code_core/test/swarm_code/protocol \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform \
  apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_os_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema \
  apps/swarm_code_daemon/test/swarm_code/daemon/backup \
  apps/swarm_code_daemon/test/swarm_code/daemon/foundation_gate_test.exs
```

Expected: all focused tests pass with no warnings, no sleeps, no residual child OS process, and no temp artifact.

- [ ] **Step 5: Run the repository gate from a clean shell**

Run: `MIX_ENV=test mix precommit`

Expected: formatting unchanged, warnings-as-errors compile succeeds, lock has no unused dependencies, every test passes, and provenance prints `provenance verified`.

- [ ] **Step 6: Audit authoritative side effects**

Run:

```bash
git status --short
git diff --check
rg -n 'Phoenix|LiveView|Bandit|Desktop|:wx|Node\.start|:net_kernel|DATABASE_PATH' apps config mix.exs
find . -type f \( -name '*.db' -o -name '*.db-wal' -o -name '*.db-shm' \) -not -path './_build/*' -print
find /tmp -maxdepth 1 -name 'swarm-code-*' -type d -print
```

Expected: only intended source/doc changes before commit; forbidden runtime search has no dependency/startup hit (documentation/error names are reviewed manually); no generated DB is tracked; test temp directories are gone.

- [ ] **Step 7: Commit**

```bash
git add README.md docs apps/swarm_code_daemon
git commit -m "feat: compose pre-repo foundation safety gate"
```

## Completion evidence required before moving to core extraction

1. `mix precommit` output from the final commit.
2. Five consecutive OS race runs proving one winner, immediate loser, graceful release, SIGKILL kernel release, and harmless stale diagnostics.
3. Reproducible manifest `cmp` against baseline commit and the two sentinel migration hashes plus 43-entry count.
4. Byte digest evidence that every incompatible-schema and injected-backup-failure test leaves source/sidecars unchanged.
5. Protocol split-point, entry/depth/size, atom-count, and queue-bound tests.
6. A clean provenance verification with authorization recorded and zero extracted source entries.
7. No claim of safe concurrent desktop/CLI use and no normal startup path until the signed macOS detector spike and later Repo supervision plan are implemented.

## Self-review against the approved foundation scope

- Umbrella/toolchain/governance/provenance: Tasks 1–2.
- Canonical paths, permissions, and process identity: Task 3.
- Adjacent Exqlite rollback-journal `BEGIN EXCLUSIVE` lease: Task 4.
- Fresh OS-process race, clean/crash release, and stale record semantics: Task 5.
- Ordered migration metadata, prefix schema hashes, SQLite floor, and read-only handshake: Task 6.
- Verified, independently restorable mode-`0600` backup before migration admission: Task 7.
- Typed, strict, atom-safe JSON plus incremental four-byte framing: Tasks 8–9.
- Pre-Repo ordering, cleanup, residual-risk copy, and full milestone gate: Task 10.

The milestone deliberately does not extract desktop source, run canonical migrations, start Repo/Bootstrap/MCP/scheduler, listen on a socket, or render a terminal. Those actions belong to later plans and cannot bypass the contracts established here.
