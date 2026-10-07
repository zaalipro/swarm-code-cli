defmodule SwarmCodeCLI.Release.ReportDetailsTest do
  @moduledoc """
  cli020 B15 (onboarding-3): a failure names cli.log only when the log has
  something in it, and never for a refusal the user fixes from the sentence
  itself (no provider, no endpoint, no model, a usage error).
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias SwarmCodeCLI.Release.PersistedSession

  setup do
    dir = Path.join(System.tmp_dir!(), "b15-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    empty = Path.join(dir, "empty.log")
    File.write!(empty, "")
    full = Path.join(dir, "full.log")
    File.write!(full, "something happened\n")
    %{empty: empty, full: full}
  end

  defp report(failure, path),
    do:
      capture_io(:stderr, fn ->
        assert PersistedSession.report(failure, path) == failure.status
      end)

  test "Details only for a log with content", c do
    failure = %{
      status: 1,
      message: "ncode could not open the conversation.",
      action: "Run ncode again."
    }

    assert report(failure, c.full) =~ "Details: " <> c.full
    refute report(failure, c.empty) =~ "Details"
    refute report(failure, c.full <> ".missing") =~ "Details"
  end

  test "never for the refusals the sentence already fixes", c do
    for reason <- [:provider_required, :endpoint_required, :model_required] do
      failure = PersistedSession.session_failure_for(reason)
      assert failure.status == 3
      refute report(failure, c.full) =~ "Details", inspect(reason)
    end

    usage = %{status: 2, message: "bad flag.", action: ""}
    refute report(usage, c.full) =~ "Details"
  end

  test "the endpoint and model sentences (B13)" do
    assert %{message: "NCODE_BASE_URL is missing (OpenAI-compatible URLs end in /v1)."} =
             PersistedSession.session_failure_for(:endpoint_required)

    assert %{
             message: "NCODE_MODEL is missing.",
             action:
               "Set NCODE_MODEL to a model of your provider, or run 'ncode settings providers'."
           } = PersistedSession.session_failure_for(:model_required)
  end
end
