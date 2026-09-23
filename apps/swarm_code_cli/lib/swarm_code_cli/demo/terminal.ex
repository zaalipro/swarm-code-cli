defmodule SwarmCodeCLI.Demo.Terminal do
  @moduledoc "Disposable interactive three-run fixture. No provider, persistence, or user data."
  alias SwarmCodeCLI.Demo.ApplicationFence
  alias SwarmCodeCLI.UI.{Init, SessionRuntime}
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias Fake.{Script, Source}
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner
  @external_resource Path.expand("../../../test/fixtures/fake/three_run_script.json", __DIR__)
  @fixture File.read!(@external_resource)

  def run(caps, flags, executable) do
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0)
    Process.unlink(supervisor)

    try do
      ApplicationFence.track_tree(supervisor)
      {:ok, script} = Script.decode(@fixture)
      source = child!(supervisor, Source, script: script, source_epoch: "terminal-demo")
      :ok = Source.advance(source, "a1-a2-b1-step-1")

      client =
        child!(supervisor, Fake,
          source: source,
          source_epoch: "terminal-demo",
          client_id: "terminal-demo"
        )

      init = %Init{
        # Composer-first (pass70 D5), like the saved and live launchers.
        focus: "composer",
        size: caps.size,
        capabilities: caps,
        source_epoch: "terminal-demo",
        destination: {:conversation, Script.id(:a)},
        now: Script.clock_ms(),
        keymap: Init.keymap_from_env()
      }

      runtime =
        child!(supervisor, SessionRuntime,
          init: init,
          data_source: client,
          frame_ms: 33,
          close_ms: 3000
        )

      monitor = Process.monitor(runtime)

      owner =
        child!(supervisor, Owner,
          runtime: runtime,
          capabilities: caps,
          flags: flags,
          executable: executable
        )

      owner_monitor = Process.monitor(owner)
      ApplicationFence.track_tree(supervisor)

      result =
        receive do
          {:DOWN, ^monitor, :process, ^runtime, :normal} -> :ok
          {:DOWN, ^monitor, :process, ^runtime, _} -> {:error, :session_failed}
        end

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, :normal} -> result
        {:DOWN, ^owner_monitor, :process, ^owner, _} -> {:error, :terminal_failed}
      after
        4000 -> {:error, :terminal_timeout}
      end
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 6000)
    end
  end

  defp child!(supervisor, module, options) do
    {:ok, pid} =
      Supervisor.start_child(
        supervisor,
        Supervisor.child_spec({module, options}, restart: :temporary, shutdown: 4000)
      )

    pid
  end
end
