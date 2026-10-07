defmodule SwarmCodeCLI.Release.HeadlessApprovalTest do
  @moduledoc """
  cli020 B23 + F8 (finisher): `ncode -p --approval <mode>` runs this one
  session's runs in that mode (in memory; the project row never changes). An
  untrusted project refuses `auto` and `full` (exit 3) before any service
  starts.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias SwarmCodeCLI.Release
  alias SwarmCodeCLI.Release.Headless

  @sentence "--approval auto and full need a trusted project. " <>
              "Run /trust in ncode first, or use --approval read-only."

  defp session(trusted_at) do
    %{
      project: %{
        id: "p1",
        root_path: System.tmp_dir!(),
        approval_mode: "read_only",
        trusted_at: trusted_at
      },
      conversation: %{id: "c1"}
    }
  end

  # The session opens (its project row says whether it is trusted); the
  # refusal comes before any child of the session starts.
  defp opened(session, test_pid) do
    fn _options, fun ->
      send(test_pid, :session_opened)
      {:ok, fun.(session)}
    end
  end

  test "an untrusted project refuses --approval auto with exit 3" do
    for mode <- ["auto", "full_access"] do
      stderr =
        capture_io(:stderr, fn ->
          assert Headless.run({:prompt, "hi", :text},
                   project_root: System.tmp_dir!(),
                   conversation: "new",
                   approval_mode: mode,
                   with_saved_session: opened(session(nil), self())
                 ) == 3
        end)

      assert stderr == "ncode: " <> @sentence <> "\n"
      assert_received :session_opened
    end
  end

  test "with --json the refusal is the not_started object" do
    {stdout, _stderr} =
      with_io(:stderr, fn ->
        capture_io(fn ->
          assert Headless.run({:prompt, "hi", :json},
                   project_root: System.tmp_dir!(),
                   conversation: "new",
                   approval_mode: "auto",
                   with_saved_session: opened(session(nil), self())
                 ) == 3
        end)
      end)

    assert %{"state" => "not_started", "error" => @sentence, "exit_code" => 3} =
             Jason.decode!(stdout)
  end

  test "the release passes the parsed mode (or the launcher's export) on" do
    assert {:ok, options} = Release.parse(["-p", "x", "--approval", "full"])
    assert options.approval == "full_access"
    assert Release.headless_options(options)[:approval_mode] == "full_access"

    assert {:ok, options} = Release.parse(["-p", "x"])
    refute Keyword.has_key?(Release.headless_options(options), :approval_mode)
  end
end
