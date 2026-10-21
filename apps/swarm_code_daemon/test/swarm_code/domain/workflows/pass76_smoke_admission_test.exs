defmodule SwarmCode.Domain.Workflows.Pass76SmokeAdmissionTest do
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

  test "source metadata and defaults are checked before protocol use", %{canary: canary} do
    forged =
      "%{__struct__: :\"Elixir.File.Stream\", path: #{inspect(canary)}, " <>
        "modes: [:write], raw: true, line_or_bytes: :line, node: :nonode@nohost}"

    for binding <- [
          "extra: %{nested: [#{forged}]}",
          "extra: :\"Elixir.Enum\"",
          "args: %{target: %{type: :map, default: %{nested: [#{forged}]}}}",
          "args: %{target: %{type: :list, default: [:\"Elixir.File.Stream\"]}}"
        ] do
      fixture = """
      meta = %{name: "smoke-fixture", description: "fixture", #{binding}}
      1
      """

      assert {:ok, definition} = Workflows.parse(fixture)

      assert "line 1: unsafe workflow data is not allowed in a workflow" in Smoke.errors(
               definition
             )

      assert {:error, problems} = Smoke.check(definition)
      assert "line 1: unsafe workflow data is not allowed in a workflow" in problems
      refute File.exists?(canary)
    end
  end

  test "final cast JSON arguments cannot introduce forged nested values", %{canary: canary} do
    fixture = """
    meta = %{name: "smoke-fixture", description: "fixture",
      args: %{target: %{type: :map}}}
    Enum.to_list(args.target["nested"])
    """

    forged = %{"nested" => %{"__struct__" => "Elixir.File.Stream", "path" => canary}}

    assert {:ok, definition} = Workflows.parse(fixture)
    assert Smoke.errors(definition) == []

    assert {:error, ["line 1: unsafe workflow data is not allowed in a workflow"]} =
             Smoke.check(definition, %{"target" => Jason.encode!(forged)})

    assert {:error, ["unsafe workflow data is not allowed in a workflow"]} =
             Smoke.check(definition, %{"carry" => %{nested: [{%{__struct__: URI}}]}})

    refute File.exists?(canary)

    assert {:ok, %Smoke{ended: :complete}} =
             Smoke.check(definition, %{"target" => ~s|{"nested": [1, 2]}|})
  end

  test "unsupported pipeline targets return source-line admission errors" do
    for {body, message} <- [
          {"\"{}\" |> (&Jason.decode/2)",
           "Jason decode options must be literal string-key options —"},
          {"\"{}\" |> (&Jason.decode!(&1, []))",
           "Jason decode options must be literal string-key options —"},
          {"[1] |> (&Enum.into/2)", "unsafe workflow data"},
          {"[1] |> (&Enum.map/2)", "unsafe workflow data"},
          {"1 |> %{}", "unsafe workflow data"},
          {"1 |> 2", "unsafe workflow data"}
        ] do
      assert "line 1: #{message} is not allowed in a workflow" in Smoke.validate_ast(
               Code.string_to_quoted!(body)
             )

      assert {:ok, definition} = Workflows.parse(source(body))
      assert Enum.any?(Smoke.errors(definition), &String.contains?(&1, message))
      assert {:error, problems} = Smoke.check(definition)
      assert Enum.any?(problems, &String.contains?(&1, message))
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

  # Reports any File.Stream protocol dispatch made by the calling process.
  defp trace_file_stream(fun) do
    for mod <- [Enumerable.File.Stream, Collectable.File.Stream, Enumerable.Map],
        do: Code.ensure_loaded!(mod)

    :erlang.trace_pattern({Enumerable.File.Stream, :_, :_}, true, [:local])
    :erlang.trace_pattern({Collectable.File.Stream, :_, :_}, true, [:local])
    :erlang.trace(self(), true, [:call])

    try do
      result = fun.()
      :erlang.trace(self(), false, [:call])
      {result, drain_traces([])}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Enumerable.File.Stream, :_, :_}, false, [:local])
      :erlang.trace_pattern({Collectable.File.Stream, :_, :_}, false, [:local])
    end
  end

  defp drain_traces(acc) do
    receive do
      {:trace, _pid, :call, mfa} -> drain_traces([mfa | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "forged meta.args is refused without any File.Stream dispatch", %{canary: canary} do
    forged =
      "%{__struct__: :\"Elixir.File.Stream\", path: #{inspect(canary)}, " <>
        "modes: [:write], raw: true, line_or_bytes: :line, node: :nonode@nohost}"

    for args <- [forged, "%{target: #{forged}}"] do
      fixture = """
      meta = %{name: "smoke-fixture", description: "fixture", args: #{args}}
      1
      """

      {result, calls} = trace_file_stream(fn -> Smoke.check(fixture, %{}, []) end)

      assert {:error, [problem]} = result
      assert problem =~ "meta.args"
      assert calls == []
      assert {:error, [_]} = Workflows.parse(fixture)
      refute File.exists?(canary)
    end
  end

  test "atom-producing word sigils cannot forge a struct collectable", %{canary: canary} do
    body = """
    pairs = ~w(__struct__ Elixir.File.Stream)a
    [key, mod] = pairs
    target = %{key => mod, path: #{inspect(canary)}, modes: [:write], raw: true,
      line_or_bytes: :line, node: :nonode@nohost}
    Enum.into(["effect"], target)
    """

    {result, calls} = trace_file_stream(fn -> Smoke.check(source(body), %{}, []) end)

    assert {:error, problems} = result
    assert Enum.any?(problems, &String.contains?(&1, "unsafe workflow data"))
    assert calls == []
    refute File.exists?(canary)

    for body <- [
          "~w(a b)a",
          "~W(a b)a",
          "~w(a b)ac",
          "Enum.into([1], %{(String.length(\"x\")) => 1})",
          "k = 1\nEnum.into([1], %{k => 1})"
        ] do
      assert {:error, problems} = Smoke.check(source(body), %{}, [])
      assert Enum.any?(problems, &String.contains?(&1, "unsafe workflow data")), body
    end

    for body <- ["~w(a b)", "~w(a b)c", "~W(a b)s", "Enum.into([1], %{\"b\" => 2, 3 => 4, a: 1})"] do
      assert Smoke.validate_ast(Code.string_to_quoted!(body)) == [], body
    end
  end

  test "atom-producing calls are rejected in every direct, piped, captured and remote spelling" do
    sigil_calls =
      for fun <- [
            "sigil_w",
            "sigil_W",
            "Kernel.sigil_w",
            "Kernel.sigil_W",
            "Elixir.Kernel.sigil_w"
          ],
          mods <- ["~c\"a\"", "~c\"ac\"", "\"a\"", "\"ca\""] do
        {fun, mods}
      end

    direct = for {fun, mods} <- sigil_calls, do: "#{fun}(\"x y\", #{mods})"
    piped = for {fun, mods} <- sigil_calls, do: "\"x y\" |> #{fun}(#{mods})"
    nested = for {fun, mods} <- sigil_calls, do: "\"x y\" |> then(&#{fun}(&1, #{mods}))"

    captured =
      for fun <- ["sigil_w", "sigil_W", "Kernel.sigil_w", "Kernel.sigil_W"],
          do: "f = &#{fun}/2\nf"

    atom_calls =
      for call <- [
            "String.to_atom(\"x\")",
            "String.to_existing_atom(\"x\")",
            "List.to_atom(~c\"x\")",
            "List.to_existing_atom(~c\"x\")",
            ":erlang.binary_to_atom(\"x\")",
            ":erlang.binary_to_existing_atom(\"x\")",
            ":erlang.list_to_atom(~c\"x\")",
            "Module.concat([\"X\"])",
            "Module.safe_concat([\"X\"])"
          ],
          source <- [
            call,
            String.replace(call, ~r/\((.*)\)$/, "") |> then(&"\"x\" |> #{&1}()"),
            "f = &#{String.replace(call, ~r/\(.*\)$/, "")}/1\nf"
          ],
          do: source

    collectables =
      for target <- ["t", "String.to_atom(\"x\")", "Map.new()", "%{k => 1}"],
          source <- [
            "Enum.into([1], #{target})",
            "[1] |> Enum.into(#{target})",
            "[1] |> Enum.into(#{target}, fn x -> x end)",
            "for x <- [1], into: #{target}, do: x",
            "f = &Enum.into/2\nf.([1], #{target})"
          ],
          do: "t = []\nk = :a\n" <> source

    for body <- direct ++ piped ++ nested ++ captured ++ atom_calls ++ collectables do
      assert {:ok, definition} = Workflows.parse(source(body)), body

      assert Enum.any?(
               Smoke.errors(definition),
               &Regex.match?(~r/unsafe workflow data|not allowed in a workflow/, &1)
             ),
             body
    end
  end

  test "atom-free sigils and literal comprehension collectables stay admitted" do
    for body <- [
          "~w(a b)",
          "\"x y\" |> sigil_w([?c])",
          "\"x y\" |> sigil_W([])",
          "for x <- [1], into: %{}, do: {x, x}",
          "for x <- [1], into: [], do: x",
          "for x <- [1], do: x"
        ] do
      assert Smoke.validate_ast(Code.string_to_quoted!(body)) == [], body
    end
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
