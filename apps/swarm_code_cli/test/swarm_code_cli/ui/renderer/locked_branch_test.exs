defmodule SwarmCodeCLI.UI.Renderer.LockedBranchTest do
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.Test.LockedBranchFixtures

  @closure ~w(compiler crypto elixir jason kernel logger stdlib swarm_code_cli swarm_code_core)a

  setup context do
    if root = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(root) end)
    :ok
  end

  test "locked branch retains only neutral dependencies and no conditional campaign outputs" do
    audit = LockedBranchFixtures.audit!()

    assert audit.cli_dependencies == [:stream_data, :swarm_code_core]
    assert audit.stream_data_options[:only] == :test
    assert audit.stream_data_options[:runtime] == false
    assert audit.runtime_closure == @closure
    assert audit.renderer_dependency_hits == []
    assert audit.conditional_paths == []
    assert audit.evidence_files == ["docs/evidence/tui-renderer/static-exratatui-013.json"]

    assert audit.runtime_sha256 ==
             "4034cb544dee1c82d8b95d66a402133e013c6b87f78ac5a26e3fba4a2fe5527b"

    assert audit.rel_env_sha256 ==
             "b448cbb5bddf63c68cc7296d0873b632d1706487b487e4b3b8c25ddbc9086000"

    assert audit.test_helper_sha256 ==
             "b086ec47f0c6c7aaeb4cffca5ae5243dd05e0dc96ab761ced93325d5315f4b12"

    assert audit.notice_renderer_hits == []
    assert audit.release_config == :absent
  end

  @tag :tmp_dir
  test "path audit finds native, release and dangling campaign outputs without blocking future candidates",
       %{tmp_dir: root} do
    expected = [
      "_build/test/lib/swarm_code_cli/priv/renderer.so",
      "_build/test/rel",
      "_build/test/rel/example",
      "apps/swarm_code_cli/lib/mix/tasks/swarm_code.tui.unplanned.ex",
      "apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013",
      "scripts/acceptance/tui_probe.sh"
    ]

    for path <-
          expected --
            [
              "_build/test/rel",
              "apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013"
            ] do
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "fixture")
    end

    renderer = Path.join(root, "apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer")
    File.mkdir_p!(Path.join(renderer, "future_candidate"))
    File.write!(Path.join(renderer, "future_candidate/adapter.ex"), "fixture")
    File.ln_s!(Path.join(root, "missing"), Path.join(renderer, "ex_ratatui_013"))
    assert LockedBranchFixtures.conditional_paths(root) == expected
  end

  @tag :tmp_dir
  test "path audit reports a symlink ancestor without reading its external target", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "outside"))
    File.ln_s!(Path.join(root, "outside"), Path.join(root, "apps"))
    assert LockedBranchFixtures.conditional_paths(root) == ["apps"]
  end

  @tag :tmp_dir
  test "wildcard scan roots and build ancestors cannot hide outputs behind links", %{
    tmp_dir: root
  } do
    outside = Path.join(root, "outside")
    File.mkdir_p!(Path.join(outside, "test/rel"))
    File.write!(Path.join(outside, "test/rel/native.so"), "fixture")

    for relative <- [
          "_build",
          "_build/test",
          "scripts/acceptance",
          "scripts/ci",
          "apps/swarm_code_cli/lib/mix/tasks"
        ] do
      fixture = Path.join(root, String.replace(relative, "/", "-"))
      target = Path.join(fixture, relative)
      File.mkdir_p!(Path.dirname(target))
      File.ln_s!(outside, target)
      assert LockedBranchFixtures.conditional_paths(fixture) == [relative]
    end
  end

  @tag timeout: 60_000
  test "actual plain command restores its app and process baseline without runtime files" do
    command = LockedBranchFixtures.run_actual_plain_command!()
    assert command["status"] == 0, command["stderr"]
    assert command["stderr"] == ""
    assert command["stdout"] == LockedBranchFixtures.plain_golden!()
    assert command["runtime_tree_before_sha256"] == command["runtime_tree_after_sha256"]
    assert byte_size(command["audit"]) <= 32_768
    assert length(String.split(command["audit"], "\n", trim: true)) == 1
    audit = Jason.decode!(command["audit"])
    expected = Enum.map(@closure, &Atom.to_string/1)

    assert audit["before"]["started_applications"] == audit["after"]["started_applications"]
    assert audit["declared_closure"] == expected
    assert audit["during"]["closure_started"] == expected
    assert audit["newly_started"] -- expected == []
    assert audit["during"]["demo_children"] == 6
    assert audit["after"]["demo_children"] == 0

    for phase <- ["before", "during", "after"] do
      assert audit[phase]["forbidden_applications"] == []
      assert audit[phase]["forbidden_processes"] == []
    end
  end
end
