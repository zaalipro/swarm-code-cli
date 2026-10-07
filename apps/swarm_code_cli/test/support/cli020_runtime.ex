defmodule SwarmCodeCLI.Test.Cli020Runtime do
  @moduledoc false
  # cli020 lane D: a SessionRuntime on the fake three-run script with this
  # test process as its full-screen terminal, and the runtime's own effects
  # delivered the way the effect runner delivers them.
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias SwarmCodeCLI.UI.{Capabilities, Init, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias Fake.{Script, Source}

  def start(opts \\ []) do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})

    client =
      start_supervised!(
        {Fake, source: source, source_epoch: "epoch", client_id: "runtime-client"}
      )

    size = %Size{columns: 160, rows: 50}
    caps = %Capabilities{size: size, full_screen?: true}

    init =
      struct!(
        %Init{
          size: size,
          capabilities: caps,
          source_epoch: "epoch",
          destination: {:conversation, Script.id(:a)},
          now: Script.clock_ms()
        },
        Keyword.get(opts, :init, [])
      )

    runtime =
      start_supervised!(
        {SessionRuntime,
         [init: init, data_source: client, frame_ms: 60_000] ++ Keyword.drop(opts, [:init])}
      )

    {:ok, _slot} = SessionRuntime.register_terminal(runtime, self(), 1, caps)
    ready(runtime)
    runtime
  end

  def conversation, do: Script.id(:a)

  def ready(runtime, attempts \\ 200)
  def ready(_, 0), do: flunk("runtime did not bind")

  def ready(runtime, n) do
    if SessionRuntime.status(runtime).phase == :running, do: :ok, else: ready(runtime, n - 1)
  end

  @doc "Delivers `effect` as the runtime's own (the effect runner's local path)."
  def effect(runtime, effect) do
    secret = :sys.get_state(runtime).secret
    send(runtime, {:owned_effect, secret, effect})
    :sys.get_state(runtime)
  end
end
