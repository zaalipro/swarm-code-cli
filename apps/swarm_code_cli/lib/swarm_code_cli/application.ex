defmodule SwarmCodeCLI.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if System.get_env("SWARM_RELEASE_TUI") == "1" do
        [
          %{
            id: SwarmCodeCLI.ReleaseSession,
            start: {Task, :start_link, [fn -> run_release_session() end]},
            restart: :temporary
          }
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: SwarmCodeCLI.Supervisor)
  end

  # pass70 B3: the release exits with the session's status (0 done, 1 failure,
  # 2 usage, 3 startup refused) and never prints a stack trace: the entry point
  # reports its own failures, and anything that still escapes is one line.
  defp run_release_session do
    status =
      try do
        SwarmCodeCLI.Release.PersistedSession.run_entry(
          System.get_env("SWARM_RELEASE_MODE") || "tui"
        )
      catch
        _kind, _reason ->
          IO.puts(:stderr, "swarmcode: stopped unexpectedly. Run it again; your work is saved.")
          1
      end

    status = if(is_integer(status) and status in 0..255, do: status, else: 1)

    # pass72 G17 (QA Q17): after a hang-up a graceful stop could wait on the
    # lost terminal forever and the VM stayed up; it halts after 10 s.
    spawn(fn ->
      Process.sleep(10_000)
      System.halt(status)
    end)

    System.stop(status)
  end
end
