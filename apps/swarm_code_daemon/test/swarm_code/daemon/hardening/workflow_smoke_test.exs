defmodule SwarmCode.Daemon.Hardening.WorkflowSmokeTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.Workflows
  alias SwarmCode.Domain.Workflows.Smoke

  @meta """
  meta = %{
    name: "smoke-fixture",
    description: "fixture",
    args: %{}
  }
  """

  defp source(body), do: @meta <> "\n" <> body

  test "rejects forged values before the canned runner evaluates them" do
    for body <- [
          "value = %{__struct__: File}\nvalue",
          "value = %URI{scheme: \"https\"}\nvalue",
          "value = Enum.into([1], collectable)\nvalue",
          "value = Enum\nvalue"
        ] do
      assert {:ok, definition} = Workflows.parse(source(body))

      assert Enum.any?(
               Smoke.errors(definition),
               &String.contains?(&1, "is not allowed in a workflow")
             )
    end
  end

  test "rejects unsafe recursive caller data without a fabricated source line" do
    assert {:ok, definition} = Workflows.parse(source("1"))

    assert {:error, ["unsafe workflow data is not allowed in a workflow"]} =
             Smoke.check(definition, %{nested: [%{__struct__: URI}]}, [])
  end

  test "admits only literal string-key Jason options in direct and piped calls" do
    for body <- [
          "Jason.decode!(\"{}\")",
          "Jason.decode(\"{}\", [])",
          "Jason.decode!(\"{}\", keys: :strings)",
          "\"{}\" |> Jason.decode!([keys: :strings])"
        ] do
      assert {:ok, definition} = Workflows.parse(source(body))
      assert Smoke.errors(definition) == []
    end

    for body <- [
          "opts = []\nJason.decode(\"{}\", opts)",
          "Jason.decode!(\"{}\", keys: :atoms)",
          "Jason.decode(\"{}\", [unknown: true])",
          "&Jason.decode/2"
        ] do
      assert {:ok, definition} = Workflows.parse(source(body))

      assert Enum.any?(
               Smoke.errors(definition),
               &String.contains?(&1, "Jason decode options must be literal string-key options")
             )
    end
  end

  test "all built-in workflows remain admitted and keep smoke result shape" do
    for definition <- Workflows.builtins() do
      assert Smoke.errors(definition) == [], definition.name
      assert {:ok, result} = Smoke.check(definition, %{}, [])
      assert %Smoke{ok?: ok?, ended: ended, phases: phases} = result
      assert is_boolean(ok?)
      assert ended in [:complete, :pause, :await_user, :budget, :error, :no_agents]
      assert is_list(phases)
    end
  end
end
