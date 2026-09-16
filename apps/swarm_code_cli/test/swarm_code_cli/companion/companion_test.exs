defmodule SwarmCodeCLI.CompanionTest do
  # The facade registers one name per VM and the last test drives a real runtime.
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.Companion
  alias SwarmCodeCLI.UI.{Capabilities, Init, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias Fake.{Script, Source}

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    :ok
  end

  test "disabled: the URL is unavailable, there is no sink, and open fails" do
    pid = start_supervised!({Companion, enabled?: false, name: nil})
    assert Companion.url(pid) == :unavailable
    assert Companion.sink(pid) == nil
    assert Companion.open(pid) == {:error, :unavailable}
  end

  test "not running: url/0 and open/0 degrade instead of exiting" do
    refute Process.whereis(Companion)
    assert Companion.url() == :unavailable
    assert Companion.open() == {:error, :unavailable}
  end

  test "open never blocks past a second and reports an opener that fails" do
    slow =
      start_supervised!({Companion, name: nil, opener: fn _ -> Process.sleep(5_000) end},
        id: :slow
      )

    {elapsed, result} = :timer.tc(fn -> Companion.open(slow) end)
    assert result == :ok and elapsed < 1_500_000

    failing =
      start_supervised!({Companion, name: nil, opener: fn _ -> {:error, :nope} end}, id: :fail)

    assert Companion.open(failing) == {:error, :nope}

    raising =
      start_supervised!({Companion, name: nil, opener: fn _ -> raise "boom" end}, id: :raise)

    assert {:error, %RuntimeError{}} = Companion.open(raising)
  end

  test "enabled: mirrors the runtime, the palette action shows the URL, focus reaches the TUI" do
    {source, client, runtime, caps} = setup_runtime()
    test = self()

    companion =
      start_supervised!(
        {Companion,
         runtime: runtime, project: "demo", opener: fn url -> send(test, {:opened, url}) end}
      )

    assert Process.whereis(Companion) == companion
    :ok = SessionRuntime.attach_companion(runtime, Companion.sink(companion))
    assert {:ok, url} = Companion.url()
    assert url =~ ~r"^http://127\.0\.0\.1:\d+/c/[A-Za-z0-9_-]{43}$"

    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)
    assert Process.alive?(source) and Process.alive?(client)

    view = eventually(fn -> view(url) end, fn v -> v["tabs"] != [] end)
    assert view["header"]["project"] == "demo"
    assert view["session"]["id"] == "epoch"
    assert Enum.any?(view["tabs"], & &1["active"])
    assert view["run"]["id"] != nil

    :ok = SessionRuntime.action(runtime, :open_companion)
    assert_receive {:opened, ^url}, 2_000
    assert SessionRuntime.snapshot(runtime).notice == {:command_feedback, "Companion: " <> url}
    assert eventually(fn -> view(url) end, fn v -> v["notice"] == "Companion: " <> url end)

    assert SessionRuntime.snapshot(runtime).focus == "main"

    {:ok, {{_, 204, _}, _, _}} =
      :httpc.request(
        :post,
        {String.to_charlist(url <> "/focus"), [], ~c"application/json", ~s({"kind":"composer"})},
        [],
        []
      )

    assert SessionRuntime.snapshot(runtime).focus == "composer"

    assert eventually(fn -> view(url) end, fn v ->
             v["focus"] == %{"kind" => "composer", "id" => nil}
           end)
  end

  defp view(url) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {String.to_charlist(url <> "/view"), []}, [], body_format: :binary)

    Jason.decode!(body)
  end

  defp eventually(fetch, check, attempts \\ 100) do
    value = fetch.()

    cond do
      check.(value) -> value
      attempts == 0 -> flunk("condition never held; last value: #{inspect(value)}")
      true -> Process.sleep(30) && eventually(fetch, check, attempts - 1)
    end
  end

  defp setup_runtime do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})

    client =
      start_supervised!(
        {Fake, source: source, source_epoch: "epoch", client_id: "companion-client"}
      )

    size = %Size{columns: 160, rows: 50}
    caps = %Capabilities{size: size}

    init = %Init{
      size: size,
      capabilities: caps,
      source_epoch: "epoch",
      destination: {:conversation, Script.id(:a)},
      now: Script.clock_ms()
    }

    runtime =
      start_supervised!({SessionRuntime, init: init, data_source: client, frame_ms: 60_000})

    {source, client, runtime, caps}
  end

  defp ready(runtime, attempts \\ 200)
  defp ready(_, 0), do: flunk("runtime did not bind")

  defp ready(runtime, n) do
    if SessionRuntime.status(runtime).phase == :running, do: :ok, else: ready(runtime, n - 1)
  end
end
