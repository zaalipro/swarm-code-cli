defmodule SwarmCodeCLI.Demo.ApplicationFenceTest do
  use ExUnit.Case, async: false

  test "starts the exact trusted closure and restores the application and logger baseline" do
    isolated!(~S"""
    before = started.()
    level = :logger.get_primary_config().level
    {during, audit} = ApplicationFence.run(fn -> started.() end)
    expected = ~w(compiler crypto elixir jason kernel logger stdlib swarm_code_cli swarm_code_core)
    assert audit.declared_closure == expected
    assert audit.during.closure_started == expected
    assert expected -- during == []
    assert audit.newly_started -- expected == []
    assert audit.before.started_applications == before
    assert audit.after.started_applications == before
    assert audit.after.demo_children == 0
    assert started.() == before
    assert :logger.get_primary_config().level == level
    """)
  end

  test "callback failure still restores the baseline and tears down tracked children" do
    isolated!(~S"""
    before = started.()
    level = :logger.get_primary_config().level
    owner = self()
    assert_raise RuntimeError, "callback failed", fn ->
      ApplicationFence.run(fn ->
        {:ok, tree} = Supervisor.start_link([{Agent, fn -> :ok end}], strategy: :one_for_one)
        ApplicationFence.track_tree(tree)
        send(owner, {:tree, tree})
        raise "callback failed"
      end)
    end
    assert_receive {:tree, tree}, 1000
    refute Process.alive?(tree)
    assert started.() == before
    assert :logger.get_primary_config().level == level
    """)
  end

  test "rejects an already running forbidden registered process before callback" do
    isolated!(~S"""
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    Process.register(pid, SwarmCode.Repo.FenceProbe)
    assert_raise RuntimeError, ~r/forbidden process/, fn ->
      ApplicationFence.run(fn -> flunk("must not enter callback") end)
    end
    send(pid, :stop)
    """)
  end

  test "rejects unsupported audit descriptors and overflow before writing" do
    isolated!(~S"""
    System.put_env("SWARM_CODE_DEMO_AUDIT_FD", "/tmp/not-an-audit-path")
    assert_raise ArgumentError, ~r/audit descriptor/, fn -> ApplicationFence.maybe_write_fd3(%{}) end
    System.put_env("SWARM_CODE_DEMO_AUDIT_FD", "3")
    assert_raise RuntimeError, ~r/exceeds bound/, fn -> ApplicationFence.maybe_write_fd3(%{oversize: String.duplicate("a", 32_768)}) end
    """)
  end

  test "the outer callback deadline restores baseline even when the callback never returns" do
    isolated!(~S"""
    before = started.()
    owner = self()
    assert_raise RuntimeError, ~r/deadline exceeded/, fn ->
      ApplicationFence.run(fn ->
        {:ok, root} = Supervisor.start_link([], strategy: :one_for_one)
        ApplicationFence.track_tree(root)
        Process.unlink(root)
        send(owner, {:early, self(), root})
        receive do: (:never -> :ok)
      end)
    end
    assert_receive {:early, callback, root}, 1000
    refute Process.alive?(callback)
    refute Process.alive?(root)
    assert started.() == before
    """)
  end

  test "Mix task rejects alternate scripts without starting applications" do
    isolated!(~S"""
    before = started.()
    assert_raise Mix.Error, "Expected --script complete", fn -> Mix.Tasks.SwarmCode.Demo.Plain.run(["--script", "other"]) end
    assert started.() == before
    """)
  end

  test "a preloaded application cannot replace the audited dependency specification" do
    isolated!(~S"""
    before = started.()
    :ok = :application.load({:application, :swarm_code_cli, [vsn: ~c"test", description: ~c"test", modules: [], applications: [:kernel, :stdlib, :unexpected_demo_dependency]]})
    assert_raise RuntimeError, ~r/differs from trusted specification/, fn ->
      ApplicationFence.run(fn -> flunk("must reject before callback or startup") end)
    end
    assert started.() == before
    assert Application.spec(:unexpected_demo_dependency) == nil
    """)
  end

  test "tracking the early tree is refreshed after children start" do
    isolated!(~S"""
    {root, audit} = ApplicationFence.run(fn ->
      {:ok, root} = Supervisor.start_link([], strategy: :one_for_one)
      Process.unlink(root)
      ApplicationFence.track_tree(root)
      {:ok, _} = Supervisor.start_child(root, {Agent, fn -> :ok end})
      ApplicationFence.track_tree(root)
      root
    end)
    assert audit.during.demo_children == 2
    assert audit.after.demo_children == 0
    refute Process.alive?(root)
    """)
  end

  test "an oversized flat tracked tree is rejected and fully stopped" do
    isolated!(~S"""
    before = started.()
    owner = self()
    assert_raise RuntimeError, "demo child bound exceeded", fn ->
      ApplicationFence.run(fn ->
        children = for index <- 1..65, do: Supervisor.child_spec({Agent, fn -> :ok end}, id: index)
        {:ok, root} = Supervisor.start_link(children, strategy: :one_for_one)
        Process.unlink(root)
        members = [root | Enum.map(Supervisor.which_children(root), &elem(&1, 1))]
        send(owner, {:oversized_tree, members})
        ApplicationFence.track_tree(root)
      end)
    end
    assert_receive {:oversized_tree, members}, 1000
    assert Enum.all?(members, &(not Process.alive?(&1)))
    assert started.() == before
    """)
  end

  test "an available optional dependency outside the fixed closure is rejected before loading" do
    isolated!(~S"""
    before = started.()
    root = Path.join(System.tmp_dir!(), "swarm-fence-optional-#{System.unique_integer([:positive])}")
    ebin = Path.join(root, "decimal-0/ebin")
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "decimal.app"), "{application,decimal,[{vsn,\"0\"},{applications,[kernel,stdlib]}]}.\n")
    true = :code.add_patha(String.to_charlist(ebin))
    try do
      assert_raise RuntimeError, "unexpected demo application closure", fn ->
        ApplicationFence.run(fn -> flunk("must reject before callback") end)
      end
      assert Application.spec(:decimal) == nil
      assert started.() == before
    after
      true = :code.del_path(String.to_charlist(ebin))
      File.rm_rf!(root)
    end
    """)
  end

  test "the actual child-project task writes exact golden output and one fd3 audit" do
    child = Path.expand("../../..", __DIR__)

    script = ~S"""
    import os, subprocess, tempfile, json, pathlib, sys
    with tempfile.TemporaryDirectory(prefix="swarm-fence-smoke-") as task_tmp:
        root = pathlib.Path(task_tmp)
        home = root / "home"
        home.mkdir()
        audit = root / "audit.json"
        env = dict(os.environ, MIX_QUIET="1", MIX_ENV="test", SWARM_CODE_DEMO_AUDIT_FD="3", HOME=str(home), XDG_CONFIG_HOME=str(home / "config"), XDG_DATA_HOME=str(home / "data"), XDG_CACHE_HOME=str(home / "cache"))
        command = ["/bin/sh", "-c", 'exec 3>"$1"; shift; exec "$@"', "fence", str(audit), sys.argv[2], "swarm_code.demo.plain", "--script", "complete"]
        result = subprocess.run(command, cwd=sys.argv[1], env=env, capture_output=True, timeout=30)
        print(json.dumps({"status":result.returncode,"stdout":result.stdout.decode(),"stderr":result.stderr.decode(),"audit":audit.read_text(),"home_files":[str(p.relative_to(home)) for p in home.rglob("*")]}))
    """

    {output, status} =
      System.cmd(
        System.find_executable("python3"),
        ["-c", script, child, System.find_executable("mix")],
        stderr_to_stdout: true
      )

    assert status == 0, output
    result = Jason.decode!(output)
    assert result["status"] == 0, result["stderr"]
    assert result["stderr"] == ""

    assert result["stdout"] ==
             File.read!(Path.expand("../../fixtures/plain/three_run_output.txt", __DIR__))

    assert result["home_files"] == []
    assert byte_size(result["audit"]) <= 32_768
    assert length(String.split(result["audit"], "\n", trim: true)) == 1
    audit = Jason.decode!(result["audit"])

    expected =
      ~w(compiler crypto elixir jason kernel logger stdlib swarm_code_cli swarm_code_core)

    assert audit["declared_closure"] == expected
    assert audit["during"]["closure_started"] == expected
    assert audit["newly_started"] -- expected == []
    assert audit["before"]["started_applications"] == audit["after"]["started_applications"]
    assert audit["during"]["demo_children"] == 6
    assert audit["after"]["demo_children"] == 0

    for phase <- ["before", "during", "after"] do
      assert audit[phase]["forbidden_applications"] == []
      assert audit[phase]["forbidden_processes"] == []
    end
  end

  defp isolated!(source) do
    allowed =
      ~w(compiler crypto elixir jason kernel logger stdlib swarm_code_cli swarm_code_core mix ex_unit)

    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.basename(&1) == "ebin"))
      |> Enum.filter(fn path ->
        directory = path |> Path.dirname() |> Path.basename()
        Enum.any?(allowed, &(directory == &1 or String.starts_with?(directory, &1 <> "-")))
      end)
      |> Enum.flat_map(&["-pa", &1])

    source = """
    import ExUnit.Assertions
    alias SwarmCodeCLI.Demo.ApplicationFence
    started = fn -> Application.started_applications() |> Enum.map(fn {app, _, _} -> Atom.to_string(app) end) |> Enum.sort() end
    #{source}
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", source],
        stderr_to_stdout: true,
        env: [{"SWARM_CODE_DEMO_AUDIT_FD", nil}]
      )

    assert status == 0, output
  end
end
