defmodule SwarmCodeCLI.UI.DataSource.C020FakeTest do
  @moduledoc """
  cli020 lane C: the `Fake` answers the new conversation commands and queries
  in the service's shapes, so lanes D and E can test against it.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Script

  defp script do
    {:ok, value} =
      Script.decode(
        File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
      )

    value
  end

  defp scope, do: %Scope{kind: :conversation, id: Script.id(:a), generation: 0}

  defp command(script, intent, id \\ "fake-1") do
    {:ok, request} =
      Request.conversation_command(intent, scope(), id, Script.clock_ms() + 1000)

    Script.command(script, request)
  end

  test "C1 queue.resume and queue.edit are accepted" do
    a = Script.id(:a)
    assert {:ok, next, %DTO.Outcome{status: :accepted}, _} = command(script(), {:queue_resume, a})

    assert {:ok, _, %DTO.Outcome{status: :accepted}, _} =
             command(next, {:queue_edit, a, "0123456789abcdef", :clear}, "fake-2")
  end
end
