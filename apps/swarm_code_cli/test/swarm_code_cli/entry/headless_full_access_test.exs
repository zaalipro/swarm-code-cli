defmodule SwarmCodeCLI.Entry.HeadlessFullAccessTest do
  @moduledoc """
  pass71 F9 (review R6): after `/approval full` in the TUI, `-p "Run touch …"`
  ran the command with an empty stderr. A one-shot in a full-access project now
  says so once on stderr before the turn; the other modes and `--plain` say
  nothing new.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias SwarmCodeCLI.Release.Headless

  test "a one-shot in full access says so on stderr" do
    session = %{project: %{approval_mode: "full_access"}}

    err =
      capture_io(:stderr, fn -> Headless.warn_full_access(session, {:prompt, "hi", :text}) end)

    assert err =~ "full access: commands and edits run without asking"

    for {session, mode} <- [
          {%{project: %{approval_mode: "auto"}}, {:prompt, "hi", :text}},
          {%{project: %{approval_mode: "read_only"}}, {:prompt, "hi", :json}},
          {session, {:plain, :text}}
        ] do
      assert capture_io(:stderr, fn -> Headless.warn_full_access(session, mode) end) == ""
    end
  end
end
