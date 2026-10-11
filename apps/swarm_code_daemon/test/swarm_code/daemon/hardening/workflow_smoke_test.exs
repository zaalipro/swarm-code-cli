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

  setup do
    root = Path.join(System.tmp_dir!(), "workflow-smoke-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{canary: Path.join(root, "canary")}
  end

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

  test "struct construction, module data and unsafe collectables never create the canary", %{
    canary: canary
  } do
    for body <- [
          "Enum.into([\"effect\"], %File.Stream{path: #{inspect(canary)}, modes: [:write]})",
          "Enum.into([\"effect\"], %{__struct__: File.Stream, path: #{inspect(canary)}, modes: [:write]})",
          "%{\"__struct__\" => \"Elixir.File.Stream\"}",
          "key = :__struct__\nMap.put(%{}, key, File.Stream)",
          "key = \"__struct__\"\nMap.put(%{}, key, :\"Elixir.File.Stream\")",
          "target = []\n[1] |> Enum.into(target)",
          "target = %{}\nEnum.into([1], target, fn x -> {x, x} end)",
          "f = &Enum.into/2\nf.([1], [])",
          "f = &Enum.into/3\nf.([1], [], fn x -> x end)",
          "String.to_existing_atom(\"Elixir.File.Stream\")",
          "List.to_existing_atom(~c\"Elixir.File.Stream\")"
        ] do
      ast = Code.string_to_quoted!(body)

      assert Enum.any?(
               Smoke.validate_ast(ast),
               &Regex.match?(
                 ~r/^line \d+: unsafe workflow data is not allowed in a workflow$/,
                 &1
               )
             ),
             body

      assert {:error, problems} = Smoke.check(source(body), %{}, [])
      assert Enum.any?(problems, &String.contains?(&1, "unsafe workflow data"))
      refute File.exists?(canary)
    end
  end

  test "rejects unsafe recursive caller data without a fabricated source line" do
    assert {:ok, definition} = Workflows.parse(source("1"))

    assert {:error, ["unsafe workflow data is not allowed in a workflow"]} =
             Smoke.check(definition, %{nested: [%{__struct__: URI}]}, [])

    for args <- [
          %{nested: {%{"__struct__" => "Elixir.URI"}}},
          %{nested: [URI]},
          %{nested: [:__struct__]},
          %{nested: fn -> :effect end},
          %{nested: [1 | :invalid]}
        ] do
      assert {:error, ["unsafe workflow data is not allowed in a workflow"]} =
               Smoke.check(definition, args, [])
    end
  end

  test "ordinary data, literal collectables and safe callbacks remain admissible" do
    for body <- [
          "Enum.into([1], [])",
          "[1] |> Enum.into([])",
          "Enum.into([1], %{}, fn x -> {x, x} end)",
          "[1] |> Enum.into(%{}, fn x -> {x, x} end)",
          "f = &Enum.map/2\nf.([1], fn x -> x + 1 end)",
          "f = &Enum.into(&1, [])\nf.([1])",
          "Map.new([1], fn x -> {x, x} end) |> Map.put(:safe, true)",
          "Enum.to_list(1..2)",
          "MapSet.new([1])",
          "~r/fixture/",
          "~D[2026-10-11]"
        ] do
      assert Smoke.validate_ast(Code.string_to_quoted!(body)) == [], body
      assert {:ok, %Smoke{ended: :complete}} = Smoke.check(source(body), %{}, [])
    end
  end

  test "admits only literal string-key Jason options in direct and piped calls" do
    for body <- [
          "Jason.decode!(\"{}\")",
          "Jason.decode(\"{}\", [])",
          "Jason.decode!(\"{}\", keys: :strings)",
          "\"{}\" |> Jason.decode!([keys: :strings])",
          ":\"Elixir.Jason\".decode!(\"{}\", [])",
          "\"{}\" |> :\"Elixir.Jason\".decode!()"
        ] do
      assert {:ok, definition} = Workflows.parse(source(body))
      assert Smoke.errors(definition) == []
    end

    for body <- [
          "opts = []\nJason.decode(\"{}\", opts)",
          "Jason.decode!(\"{}\", keys: :atoms)",
          "Jason.decode(\"{}\", [unknown: true])",
          "Jason.decode(\"{}\", [keys: :strings, keys: :strings])",
          "Jason.decode!(\"{}\", %{keys: :strings})",
          "Jason.decode!(\"{}\", fn -> [] end)",
          "opts = [keys: :atoms]\n\"{}\" |> Jason.decode!(opts)",
          ":\"Elixir.Jason\".decode!(\"{}\", keys: :atoms!)",
          "&Jason.decode/1",
          "&Jason.decode/2",
          "&Jason.decode!/2",
          "&Jason.decode!(&1, [])"
        ] do
      assert {:ok, definition} = Workflows.parse(source(body))

      assert Enum.any?(
               Smoke.errors(definition),
               &String.contains?(&1, "Jason decode options must be literal string-key options")
             )

      assert {:error, _problems} = Smoke.check(source(body), %{}, [])
    end

    assert {:ok, %Smoke{ended: :complete}} =
             Smoke.check(source(~s|decoded = Jason.decode!("{\\"fixture\\": 1}", [])
               if Map.has_key?(decoded, "fixture"), do: :ok, else: raise("atomized")|), %{}, [])
  end

  test "all built-in workflows remain admitted and keep smoke result shape" do
    for definition <- Workflows.builtins() do
      assert Smoke.errors(definition) == [], definition.name
      assert {:ok, result} = Smoke.check(definition, %{}, [])
      assert %Smoke{ok?: ok?, ended: ended, phases: phases} = result
      assert is_boolean(ok?)

      assert {ended, result.agents_total, result.max_panel, result.gates} ==
               Map.fetch!(
                 %{
                   "mission" => {:complete, 0, 0, 0},
                   "research" => {:complete, 6, 4, 0},
                   "review-changes" => {:complete, 5, 4, 0}
                 },
                 definition.name
               )

      assert result.ok?
      assert is_list(result.trace)
      assert is_list(result.warnings)
      assert is_list(phases)
    end
  end
end
