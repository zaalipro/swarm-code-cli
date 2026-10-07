defmodule SwarmCodeCLI.Release.HeadlessJsonTest do
  @moduledoc """
  cli020 B4 (bugs-10): `-p … --json` prints its summary object on stdout
  even when the session never started.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias SwarmCodeCLI.Release.Headless

  test "a refused startup with --json prints a decodable object with exit_code 3" do
    refused = fn _options, _fun ->
      {:error, %{status: 3, message: "No model provider is set up yet.", action: ""}}
    end

    {stdout, stderr} =
      with_io(:stderr, fn ->
        capture_io(fn ->
          assert Headless.run({:prompt, "hi", :json},
                   project_root: System.tmp_dir!(),
                   conversation: "new",
                   with_saved_session: refused
                 ) == 3
        end)
      end)

    assert stderr =~ "ncode: No model provider is set up yet."

    assert %{
             "state" => "not_started",
             "conversation_id" => nil,
             "run_id" => nil,
             "text" => "",
             "error" => "No model provider is set up yet.",
             "question" => nil,
             "denied" => [],
             "exit_code" => 3
           } = Jason.decode!(stdout)
  end

  test "text mode and a zero code print no object" do
    assert capture_io(fn -> assert Headless.json_failure({:prompt, "x", :text}, "no", 3) == 3 end) ==
             ""

    assert capture_io(fn -> assert Headless.json_failure(:json, "fine", 0) == 0 end) == ""
  end

  # cli020 B23: a stream-json run that never starts still ends with its summary.
  test "stream-json failures print the summary record" do
    out =
      ExUnit.CaptureIO.capture_io(fn ->
        assert SwarmCodeCLI.Release.Headless.json_failure({:prompt, "x", :stream_json}, "no", 3) == 3
      end)

    assert %{"type" => "summary", "error" => "no", "exit_code" => 3} = Jason.decode!(out)
  end
end
