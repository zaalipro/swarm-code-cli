defmodule SwarmCodeCLI.UI.LayersTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Switcher, Editor, State}

  test "switcher closed prefixes, stable rank and no results" do
    entries = [
      struct(Switcher.Entry,
        id: "r",
        kind: :run,
        label: "Review run",
        target: {:local, {:navigate, {:run, "r"}}}
      ),
      struct(Switcher.Entry,
        id: "a",
        kind: :action,
        label: "Review action",
        target: {:local, :back}
      )
    ]

    query = fn text -> elem(Editor.apply(Editor.new(), {:insert, text}), 1) end
    # `#` lists conversations and researches; runs are Ctrl-R's (pass70 Q10).
    assert Switcher.rank(query.("#review"), entries) == []
    assert Enum.map(Switcher.rank(query.(">review"), entries), & &1.id) == ["a"]
    assert Switcher.rank(query.("@review"), entries) == []
    assert Switcher.repair_selection("r", 0, entries) == "r"
    assert Switcher.repair_selection("gone", 1, entries) == "a"
    assert Switcher.repair_selection("gone", 1, []) == "query"
    assert {:switcher, _} = Switcher.open(%State{}, "main")
  end

  test "every current local action retains an action-menu route without parsing its ID" do
    target = {:local, {:open_detail, "run", "ref"}}
    entries = Switcher.entries(%State{}, %{"not-a-command" => target})
    assert Enum.any?(entries, &(&1.target == target))
    query = elem(Editor.apply(Editor.new(), {:insert, "full detail"}), 1)
    assert Enum.any?(Switcher.rank(query, entries), &(&1.target == target))
  end

  # The visual companion has no key binding, so the palette is its only door.
  test "the palette lists the visual companion as one local action" do
    entries = Switcher.entries(%State{}, %{})
    assert entry = Enum.find(entries, &(&1.label == "Open visual companion"))
    assert entry.kind == :action
    assert entry.target == {:local, :open_companion}
    assert {:ok, _target} = SwarmCodeCLI.UI.ActionTarget.validate(entry.target)

    query = elem(Editor.apply(Editor.new(), {:insert, ">visual"}), 1)
    assert Enum.any?(Switcher.rank(query, entries), &(&1.target == entry.target))
  end
end
