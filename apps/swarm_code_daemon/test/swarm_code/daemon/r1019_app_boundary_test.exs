defmodule SwarmCode.Daemon.R1019AppBoundaryTest do
  @moduledoc """
  pass 77 C-ARCH-6 (first step): pins the cross-app coupling of the test trees
  as it is, so that it cannot grow. The daemon's tests drive the terminal
  client over the real socket, and a few of the CLI's tests reach into the
  daemon's modules; both are listed below, exactly. A new test that crosses
  the apps is not an accident to wave through: it belongs in the release app
  (C-ARCH-6), where both sides are dependencies, and a test that no longer
  crosses is removed from the list.
  """
  use ExUnit.Case, async: true

  # The needles are built, so that this file does not match itself.
  @cli "SwarmCode" <> "CLI."
  @core ~r/SwarmCode\.(Domain|Daemon)\./

  @daemon_tests Path.expand("../..", __DIR__)
  @cli_tests Path.expand("../../../../swarm_code_cli/test", __DIR__)

  # Daemon test files that name a SwarmCodeCLI module (relative to test/).
  @daemon_files_using_cli [
    "swarm_code/daemon/hardening/events_test.exs",
    "swarm_code/daemon/service/c020_dispatcher_test.exs",
    "swarm_code/daemon/service/c020_projection_test.exs",
    "swarm_code/daemon/service/cli021_int_vitals_e2e_test.exs",
    "swarm_code/daemon/service/cli021_vitals_backend_test.exs",
    "swarm_code/daemon/service/cli022_effective_effort_test.exs",
    "swarm_code/daemon/service/cli022_int_effort_e2e_test.exs",
    "swarm_code/daemon/service/cli022_quit_summary_test.exs",
    "swarm_code/daemon/service/clipboard_inbox_test.exs",
    "swarm_code/daemon/service/desktop_presence_test.exs",
    "swarm_code/daemon/service/live_backend_test.exs",
    "swarm_code/daemon/service/pass70_approval_test.exs",
    "swarm_code/daemon/service/pass70_changes_test.exs",
    "swarm_code/daemon/service/pass70_conversation_test.exs",
    "swarm_code/daemon/service/pass70_qa_queue_test.exs",
    "swarm_code/daemon/service/pass70_session_commands_test.exs",
    "swarm_code/daemon/service/pass70_socket_test.exs",
    "swarm_code/daemon/service/pass72_panel_wire_test.exs",
    "swarm_code/daemon/service/pass73_send_routing_test.exs",
    "swarm_code/daemon/service/pass73_session_flow_test.exs",
    "swarm_code/daemon/service/pass76_elsewhere_test.exs",
    "swarm_code/daemon/service/persisted_backend_test.exs",
    "swarm_code/daemon/service/question_projection_test.exs",
    "swarm_code/daemon/service/read_only_ask_test.exs",
    "swarm_code/daemon/service/retry_run_test.exs",
    "swarm_code/daemon/service/settings/c74_backend_settings_test.exs",
    "swarm_code/daemon/service/settings/c74_client_e2e_test.exs",
    "swarm_code/daemon/service/settings/c74_feature_errors_test.exs",
    "swarm_code/daemon/service/settings/c74_qa2_e2e_test.exs",
    "swarm_code/daemon/service/settings/cli021_c1_fetch_models_test.exs",
    "swarm_code/daemon/service/shell_escape_test.exs",
    "swarm_code/daemon/service/wire_contract_test.exs"
  ]

  # CLI test files that name a SwarmCode.Domain or SwarmCode.Daemon module
  # (relative to test/).
  @cli_files_using_daemon [
    "swarm_code_cli/entry/c74_config_command_test.exs",
    "swarm_code_cli/entry/exit_summary_test.exs",
    "swarm_code_cli/entry/headless_follow_test.exs",
    "swarm_code_cli/entry/orbit_e2e_test.exs",
    "swarm_code_cli/entry/reasons_test.exs",
    "swarm_code_cli/entry/resume_selection_test.exs",
    "swarm_code_cli/entry/signals_close_test.exs",
    "swarm_code_cli/entry/signals_test.exs",
    "swarm_code_cli/persisted_session_release_test.exs",
    "swarm_code_cli/plain/live_session_test.exs",
    "swarm_code_cli/ui/data_source/library_service_test.exs",
    "swarm_code_cli/ui/data_source/live_service_test.exs",
    "swarm_code_cli/ui/data_source/runtime_service_test.exs"
  ]

  test "the daemon's tests that use the terminal client are exactly the listed ones" do
    found = files_matching(@daemon_tests, &String.contains?(&1, @cli), __ENV__.file)
    assert_pinned(found, @daemon_files_using_cli, "daemon", "SwarmCodeCLI")
  end

  test "the CLI's tests that use the daemon's modules are exactly the listed ones" do
    found = files_matching(@cli_tests, &Regex.match?(@core, &1), __ENV__.file)
    assert_pinned(found, @cli_files_using_daemon, "CLI", "SwarmCode.Domain/SwarmCode.Daemon")
  end

  defp assert_pinned(found, listed, side, needle) do
    new = found -- listed
    gone = listed -- found

    assert new == [],
           "a test that crosses apps belongs in the release app (C-ARCH-6): the #{side} tests " <>
             "#{inspect(new)} name #{needle} and are not in the list"

    assert gone == [],
           "these #{side} tests no longer cross apps; remove them from the list: #{inspect(gone)}"
  end

  defp files_matching(root, matches?, self) do
    assert File.dir?(root), "#{root} is not a test tree"

    root
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.reject(&(&1 == self))
    |> Enum.filter(&(&1 |> File.read!() |> matches?.()))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end
end
