defmodule SwarmCodeCLI.Test.LockedBranchFixtures do
  @moduledoc "Local, isolated audit of the exact rejected ExRatatui campaign; no remote operations."

  @root Path.expand("../../../..", __DIR__)
  @child Path.join(@root, "apps/swarm_code_cli")
  @renderer_names ~r/ex_ratatui|ratatui|rustler|crossterm/i
  # These are Task 28's conditional campaign outputs, not a ban on new candidate designs.
  @conditional_paths ~w(
    .github/workflows/tui-native-bootstrap.yml
    governance/tui-evidence-allowed-signers governance/tui-license-policy.json governance/tui-license-inputs.json
    third_party/tui-license-texts rust-toolchain-tui-sanitizer.toml
    deps/ex_ratatui deps/rustler deps/rustler_precompiled
    rel/vm.args.eex rel/overlays/bin/swarm-code-demo
    apps/swarm_code_cli/lib/swarm_code_cli/application.ex
    apps/swarm_code_cli/lib/swarm_code_cli/demo/supervisor.ex
    apps/swarm_code_cli/lib/swarm_code_cli/demo/main.ex
    apps/swarm_code_cli/lib/swarm_code_cli/release
    apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013
    apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/cell.ex
    apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/cell_frame.ex
    apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/golden.ex
    apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/probe.ex
    apps/swarm_code_cli/lib/swarm_code_cli/ui/terminal_owner.ex
    apps/swarm_code_cli/lib/swarm_code_cli/ui/ui_supervisor.ex
    apps/swarm_code_cli/lib/swarm_code_cli/ui/launcher_control.ex
    apps/swarm_code_cli/lib/mix/tasks/swarm_code.tui.goldens.ex
    apps/swarm_code_cli/lib/mix/tasks/swarm_code.tui.release_manifest.ex
    apps/swarm_code_cli/lib/mix/tasks/swarm_code.tui.evidence.ex
    apps/swarm_code_cli/test/fixtures/goldens/ex_ratatui_013
    apps/swarm_code_cli/test/fixtures/renderer
    apps/swarm_code_cli/test/fixtures/evidence
    apps/swarm_code_cli/test/fixtures/release
    apps/swarm_code_cli/test/support/pty_harness.ex
    apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_input_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_boundary_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_matrix_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/fuzz_orchestrator_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/unicode_input_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/performance_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/resource_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_owner_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/launcher_control_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_lifecycle_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/demo/application_test.exs
    apps/swarm_code_cli/test/swarm_code_cli/release
  )

  def audit! do
    metadata = project_metadata!()
    tree = command!("mix", ["deps.tree", "--only", "prod"], cd: @child)

    sources =
      for path <- ["mix.exs", "apps/swarm_code_cli/mix.exs", "mix.lock"],
          do: {path, File.read!(Path.join(@root, path))}

    %{
      cli_dependencies: metadata.cli_dependencies,
      stream_data_options: metadata.stream_data_options,
      runtime_closure: metadata.runtime_closure,
      renderer_dependency_hits: name_hits(sources ++ [{"prod dependency tree", tree}]),
      conditional_paths: conditional_paths(@root),
      evidence_files: descendants(@root, "docs/evidence/tui-renderer"),
      runtime_sha256: sha256("config/runtime.exs"),
      rel_env_sha256: sha256("rel/env.sh.eex"),
      test_helper_sha256: sha256("apps/swarm_code_cli/test/test_helper.exs"),
      notice_renderer_hits: name_hits([{"NOTICE", File.read!(Path.join(@root, "NOTICE"))}]),
      release_config: if(metadata.release_config, do: :present, else: :absent)
    }
  end

  defp project_metadata! do
    # Only the child project is run. The root project is inspected without loading
    # its umbrella children or starting applications; .app files are trusted data.
    source = ~S"""
    deps = Mix.Project.config()[:deps]
    stream_options = case List.keyfind(deps, :stream_data, 0) do
      {_, _, options} -> options
      {_, options} -> options
      nil -> []
    end
    read_closure = fn read_closure, pending, seen ->
      case pending do
        [] -> seen |> MapSet.to_list() |> Enum.sort()
        [app | rest] ->
          if MapSet.member?(seen, app) do
            read_closure.(read_closure, rest, seen)
          else
            path = :code.where_is_file(Atom.to_charlist(app) ++ ~c".app")
            {:ok, [{:application, ^app, spec}]} = :file.consult(path)
            optional = Keyword.get(spec, :optional_applications, [])
            required = (Keyword.get(spec, :applications, []) ++ Keyword.get(spec, :included_applications, []))
              |> Enum.reject(&(&1 in optional and :code.lib_dir(&1) == {:error, :bad_name}))
            read_closure.(read_closure, required ++ rest, MapSet.put(seen, app))
          end
      end
    end
    runtime_closure = read_closure.(read_closure, [:swarm_code_cli], MapSet.new())
    child_release = Keyword.has_key?(Mix.Project.config(), :releases)
    root_release = Mix.Project.in_project(:locked_root_audit, "../..", fn _ ->
      Keyword.has_key?(Mix.Project.config(), :releases)
    end)
    result = %{
      cli_dependencies: Enum.map(deps, &elem(&1, 0)) |> Enum.sort(),
      stream_data_options: stream_options,
      runtime_closure: runtime_closure,
      release_config: child_release or root_release
    }
    IO.puts("LOCKED_AUDIT=" <> Base.encode64(:erlang.term_to_binary(result)))
    """

    output =
      command!("mix", ["run", "--no-start", "--no-compile", "-e", source],
        cd: @child,
        env: [{"MIX_ENV", "test"}, {"SWARM_CODE_DEMO_AUDIT_FD", nil}]
      )

    [encoded] = for "LOCKED_AUDIT=" <> value <- String.split(output, "\n"), do: value
    encoded |> Base.decode64!() |> :erlang.binary_to_term()
  end

  @doc "Enumerates the locked campaign outputs without traversing symlinks."
  def conditional_paths(root) do
    exact =
      Enum.flat_map(@conditional_paths, fn path ->
        case lstat_without_links(root, path) do
          {:ok, _} -> [path]
          {:symlink, link} -> [link]
          {:error, :enoent} -> []
          {:error, reason} -> raise File.Error, reason: reason, action: "audit", path: path
        end
      end)

    scripts =
      for directory <- ["scripts/acceptance", "scripts/ci"],
          path <- children(root, directory),
          String.starts_with?(Path.basename(path), "tui_"),
          do: path

    tasks =
      for path <- children(root, "apps/swarm_code_cli/lib/mix/tasks"),
          String.starts_with?(Path.basename(path), "swarm_code.tui."),
          do: path

    scan_roots = [
      "_build",
      "apps/swarm_code_cli/priv",
      "scripts/acceptance",
      "scripts/ci",
      "apps/swarm_code_cli/lib/mix/tasks"
    ]

    root_links =
      Enum.flat_map(scan_roots, fn path ->
        case lstat_without_links(root, path) do
          {:symlink, link} -> [link]
          _ -> []
        end
      end)

    native =
      for path <- descendants(root, "_build") ++ descendants(root, "apps/swarm_code_cli/priv"),
          conditional_build_path?(path) or uninspectable_build_link?(root, path),
          do: path

    Enum.sort(Enum.uniq(exact ++ scripts ++ tasks ++ native ++ root_links))
  end

  defp uninspectable_build_link?(root, path) do
    case lstat_without_links(root, path) do
      {:symlink, _} ->
        # Mix links dependency source/assets here. They are outside the CLI/native
        # library scope, and we never follow them. Build roots, app roots, release
        # paths and CLI/native links remain findings.
        case Path.split(path) do
          ["_build", _, "lib", app, leaf] when leaf in ["priv", "src"] ->
            app in ["swarm_code_cli", "ex_ratatui", "rustler", "rustler_precompiled"]

          _ ->
            true
        end

      _ ->
        false
    end
  end

  defp conditional_build_path?(path) do
    components = Path.split(path)

    campaign_app =
      Enum.any?(components, &(&1 in ["ex_ratatui", "rustler", "rustler_precompiled"]))

    assembled_release = match?(["_build", _, "rel" | _], components)

    cli_native =
      ("swarm_code_cli" in components or campaign_app) and
        (Path.extname(path) in [".so", ".dylib", ".dll"] or
           Path.basename(path) == "erl_crash.dump")

    campaign_app or assembled_release or cli_native
  end

  # Include symlinks (even dangling ones) as findings but never recurse into them.
  defp descendants(root, relative) do
    case lstat_without_links(root, relative) do
      {:ok, %{type: :directory}} ->
        Enum.flat_map(children(root, relative), fn child ->
          [child | descendants(root, child)]
        end)

      {:symlink, link} ->
        [link]

      {:ok, _} ->
        []

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "audit", path: relative
    end
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp children(root, relative) do
    case lstat_without_links(root, relative) do
      {:ok, %{type: :directory}} ->
        Path.join(root, relative)
        |> File.ls!()
        |> Enum.map(&Path.join(relative, &1))
        |> Enum.sort()

      {:ok, _} ->
        []

      {:symlink, _} ->
        []

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "audit", path: relative
    end
  end

  defp lstat_without_links(root, relative) do
    Enum.reduce_while(Path.split(relative), "", fn component, previous ->
      path = Path.join(previous, component)

      case File.lstat(Path.join(root, path)) do
        {:ok, %{type: :symlink}} -> {:halt, {:symlink, path}}
        {:ok, stat} when path == relative -> {:halt, {:ok, stat}}
        {:ok, _} -> {:cont, path}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp name_hits(sources) do
    for {label, bytes} <- sources,
        [name] <- Regex.scan(@renderer_names, bytes),
        do: {label, name}
  end

  defp sha256(path),
    do:
      Path.join(@root, path)
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  def plain_golden!, do: File.read!(Path.join(@child, "test/fixtures/plain/three_run_output.txt"))

  @doc "Runs the real Task 15 command in an owned temporary HOME/XDG tree, removed by Python's finally cleanup."
  def run_actual_plain_command! do
    script = ~S"""
    import os, subprocess, tempfile, json, pathlib, sys, hashlib, stat
    def fingerprint(directory):
        entries = []
        def visit(path):
            info = path.lstat()
            relative = str(path.relative_to(directory))
            if stat.S_ISLNK(info.st_mode):
                entries.append([relative, "symlink", os.readlink(path)])
            elif stat.S_ISDIR(info.st_mode):
                entries.append([relative, "directory"])
                for child in sorted(path.iterdir()): visit(child)
            else:
                entries.append([relative, "file", hashlib.sha256(path.read_bytes()).hexdigest()])
        visit(directory)
        return hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="swarm-locked-plain-") as task_tmp:
        root = pathlib.Path(task_tmp)
        runtime = root / "runtime"
        home = runtime / "home"
        home.mkdir(parents=True)
        for name in ("config", "data", "cache"): (runtime / name).mkdir()
        audit = root / "audit.json"
        env = dict(os.environ, MIX_QUIET="1", MIX_ENV="test", SWARM_CODE_DEMO_AUDIT_FD="3", HOME=str(home), XDG_CONFIG_HOME=str(runtime / "config"), XDG_DATA_HOME=str(runtime / "data"), XDG_CACHE_HOME=str(runtime / "cache"))
        command = ["/bin/sh", "-c", 'exec 3>"$1"; shift; exec "$@"', "locked-fence", str(audit), sys.argv[2], "swarm_code.demo.plain", "--script", "complete"]
        before = fingerprint(runtime)
        result = subprocess.run(command, cwd=sys.argv[1], env=env, capture_output=True, timeout=30)
        after = fingerprint(runtime)
        print(json.dumps({"status": result.returncode, "stdout": result.stdout.decode(), "stderr": result.stderr.decode(), "audit": audit.read_text(), "runtime_tree_before_sha256": before, "runtime_tree_after_sha256": after}))
    """

    command!("python3", ["-c", script, @child, System.find_executable("mix")]) |> Jason.decode!()
  end

  defp command!(executable, arguments, options \\ []) do
    {output, status} =
      System.cmd(
        System.find_executable(executable),
        arguments,
        Keyword.put(options, :stderr_to_stdout, true)
      )

    if status != 0, do: raise("locked branch #{executable} audit failed (#{status}): #{output}")
    output
  end
end
