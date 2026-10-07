defmodule SwarmCode.Daemon.Service.DesktopPresenceTest do
  @moduledoc """
  cli020 C4 (bugs-6): the backend tells the shell watch when the ncode app
  opens on the same database, and the workspace carries it.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  setup_all do
    setup_world("desktop")
  end

  test "a desktop_running message reaches the shell watch once", c do
    {:ok, conv} = Conversations.create(c.project.id)
    backend = start_backend(c, conv)
    shell = %Scope{kind: :global, id: nil, generation: 3}

    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 5000,
      params: %{
        "watch_ref" => "shell-1",
        "slot" => "shell",
        "page_size" => 50,
        "byte_limit" => 1_048_576
      }
    }

    assert {:watch, 0, _, _, _} =
             GenServer.call(backend, {:service_watch, self(), id("w"), shell, watch})

    send(backend, {:service_ready, self(), "shell-1"})
    refute workspace(backend, scope(conv))["desktop_running"]
    send(backend, {:desktop_running, true})
    send(backend, {:desktop_running, true})

    assert_receive {:service_delta, ^backend, "shell-1", %{"kind" => "desktop_running"} = wire},
                   2_000

    assert {:ok, %Delta{kind: :desktop_running, body: %DTO.DesktopPresence{running: true}}} =
             Delta.decode(wire)

    refute_receive {:service_delta, ^backend, "shell-1", %{"kind" => "desktop_running"}}, 200
    assert workspace(backend, scope(conv))["desktop_running"] == true
  end
end
