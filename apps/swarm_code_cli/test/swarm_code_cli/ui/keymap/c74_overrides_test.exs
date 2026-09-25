defmodule SwarmCodeCLI.UI.Keymap.C74OverridesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SwarmCodeCLI.UI.Keymap.{Bindings, KeyName, Overrides}
  alias SwarmCodeCLI.UI.Projector.KeyLabel

  describe "KeyName.parse/1 and name/1" do
    for {name, keys} <- [
          {"Ctrl-L", [{"l", [:control]}]},
          {"ctrl-l", [{"l", [:control]}]},
          {"CTRL-l", [{"l", [:control]}]},
          {"Alt-Enter", [{:enter, [:alt]}]},
          {"Shift-Tab", [{:back_tab, []}, {:tab, [:shift]}]},
          {"F5", [{{:function, 5}, []}]},
          {"f12", [{{:function, 12}, []}]},
          {"PageDown", [{:page_down, []}]},
          {"pgup", [{:page_up, []}]},
          {"x", [{"x", []}]},
          {"X", [{"X", []}]},
          {"?", [{"?", []}]},
          {"Space", [{" ", []}]},
          {"Ctrl-Space", [{" ", [:control]}]},
          {"Esc", [{:escape, []}]},
          {"Up", [{:up, []}]},
          {"Shift-Up", [{:up, [:shift]}]},
          {"Ctrl-Alt-H", [{"h", [:alt, :control]}]},
          {"Alt-l", [{"l", [:alt]}]},
          {"Delete", [{:delete, []}]}
        ] do
      test "#{name}" do
        assert KeyName.keys(unquote(name)) == {:ok, unquote(Macro.escape(keys))}
        assert {:ok, key} = KeyName.parse(unquote(name))
        assert key == hd(unquote(Macro.escape(keys)))
      end
    end

    for name <- ["Ctrl-Shift-A", "Ctrl-Enter", "Ctrl-Tab", "Shift-Enter", "Ctrl-I", "Ctrl-M"] do
      test "#{name} parses but cannot be reported" do
        assert {:ok, _key} = KeyName.parse(unquote(name))
        assert {:error, "this terminal cannot report " <> _} = KeyName.keys(unquote(name))
      end
    end

    for name <- ["", "Ctrl-", "Hyper-X", "Ctrl-Ctrl-L", "ab", "F13", "Ctrl-Shift", "Shift-x"] do
      test "#{inspect(name)} is not a key name" do
        assert KeyName.parse(unquote(name)) == {:error, "not a key name"}
      end
    end

    test "stored names and printed names" do
      assert KeyName.name({"l", [:control]}) == "Ctrl-L"
      assert KeyName.name({:page_down, []}) == "PageDown"
      assert KeyName.name({:back_tab, []}) == "Shift-Tab"
      assert KeyName.name({" ", []}) == "Space"
      assert KeyName.name({"h", [:alt, :control]}) == "Ctrl-Alt-H"
      assert KeyName.format({:up, []}, :rich) == "↑"
      assert KeyName.format({:up, []}, :measured) == "↑"
      assert KeyName.format({:up, []}, :ascii) == "Up"
      assert KeyName.format("Ctrl-L", :rich) == "Ctrl-L"

      assert KeyName.canonical("ctrl-shift-tab") ==
               {:error, "this terminal cannot report Ctrl-Shift-Tab"}

      assert KeyName.canonical("pgdn") == {:ok, "PageDown"}
    end

    property "every table key's stored name parses back to it" do
      keys =
        Bindings.all()
        |> Enum.flat_map(& &1.keys)
        |> Enum.uniq()
        |> Enum.reject(fn {code, mods} ->
          # permutations the table lists for robustness, not spellings
          (is_binary(code) and :shift in mods) or
            (is_binary(code) and :control in mods and
               code != String.downcase(code))
        end)

      check all(key <- member_of(keys)) do
        assert {:ok, parsed} = KeyName.parse(KeyName.name(key))
        assert key in KeyName.expand(parsed)
      end
    end
  end

  describe "compile/1" do
    test "an override moves the palette to F5; hints print F5" do
      ov = Overrides.compile(%{"command_palette" => ["F5"]})
      assert ov.errors == []
      assert Overrides.keys_for(ov, :command_palette) == [{{:function, 5}, []}]
      assert %{id: :command_palette} = Overrides.lookup(ov, :main, {:function, 5}, [])
      assert Overrides.lookup(ov, :main, "p", [:control]) == :unbound
      assert Overrides.lookup(ov, :main, "g", [:control]) == :default

      binding = Overrides.effective_binding(ov, :command_palette)
      assert KeyLabel.primary(binding) == "F5"
    end

    test "[] unbinds a binding" do
      ov = Overrides.compile(%{"command_palette" => []})
      assert ov.errors == []
      assert Overrides.keys_for(ov, :command_palette) == []
      assert Overrides.effective_keys(ov, :command_palette) == []
      assert Overrides.lookup(ov, :composer, "p", [:control]) == :unbound
    end

    test "fixed bindings cannot be remapped or unbound" do
      ov = Overrides.compile(%{"help" => ["F5"], "confirm_yes" => [], "hint_pick" => ["x"]})
      assert Overrides.keys_for(ov, :help) == :default

      assert {"confirm_yes", ~s("#{Bindings.fetch(:confirm_yes).label}" cannot be unbound)} in ov.errors
      assert {"help", ~s("Help" cannot be remapped)} in ov.errors
      assert length(ov.errors) == 3
    end

    test "fixed keys cannot be taken" do
      for name <- ["Esc", "Enter", "Up", "Down", "Left", "Right", "Ctrl-C", "?", "F1", "Ctrl-S"] do
        assert Overrides.check(nil, "command_palette", [name]) == {:error, "#{name} is fixed"},
               name
      end
    end

    test "approval letters cannot be taken; a taken key names its holder and contexts" do
      assert {:error, "y is fixed"} = Overrides.check(nil, "runs_dashboard", ["y"])

      assert {:error, message} = Overrides.check(nil, "command_palette", ["Ctrl-G"])
      assert message =~ ~s(Ctrl-G is taken by "Runs" in )
      assert message =~ "main"
    end

    test "unreportable and malformed keys; 4 keys at most; unknown ids" do
      assert {:error, "this terminal cannot report Ctrl-Shift-A"} =
               Overrides.check(nil, "command_palette", ["Ctrl-Shift-A"])

      assert {:error, "not a key name"} = Overrides.check(nil, "command_palette", ["Hyper-P"])

      assert {:error, "4 keys at most"} =
               Overrides.check(nil, "command_palette", ["F5", "F6", "F7", "F8", "F9"])

      ov = Overrides.compile(%{"no_such_binding" => ["F5"]})
      assert [{"no_such_binding", _}] = ov.errors
    end

    test "a swap of two bindings in one write is accepted" do
      ov =
        Overrides.compile(%{"command_palette" => ["Ctrl-G"], "runs_dashboard" => ["Ctrl-P"]})

      assert ov.errors == []
      assert %{id: :command_palette} = Overrides.lookup(ov, :main, "g", [:control])
      assert %{id: :runs_dashboard} = Overrides.lookup(ov, :main, "p", [:control])
    end

    test "swap/3 builds the change set for the capture editor" do
      assert {:ok, source} = Overrides.swap(nil, "command_palette", ["Ctrl-G"])
      assert source["command_palette"] == ["Ctrl-G"]
      assert source["runs_dashboard"] == ["Ctrl-P"]
      assert Overrides.compile(source).errors == []
    end

    test "an invalid entry never breaks the others and is reported (AT14)" do
      ov = Overrides.compile(%{"command_palette" => ["F5"], "help" => ["F6"]})
      assert Overrides.keys_for(ov, :command_palette) == [{{:function, 5}, []}]
      assert {"1 key override in cli.json were ignored", "help: " <> _} = Overrides.attention(ov)
      assert Overrides.attention(Overrides.compile(%{})) == nil
    end

    test "not a map" do
      assert %Overrides{errors: [_]} = Overrides.compile(["F5"])
      assert %Overrides{errors: []} = Overrides.compile(nil)
    end
  end

  describe "bindings_for_key/2" do
    test "Ctrl-J lists every binding and context" do
      results = Overrides.bindings_for_key(nil, "Ctrl-J")
      assert results != []

      expected =
        Bindings.table()
        |> Enum.filter(fn {{_ctx, key}, _} -> key == {"j", [:control]} end)
        |> Enum.map(fn {{ctx, _}, _} -> ctx end)
        |> Enum.sort()

      assert results |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort() == expected
    end

    test "follows the overrides" do
      ov = Overrides.compile(%{"command_palette" => ["F5"]})
      assert [{%{id: :command_palette}, contexts}] = Overrides.bindings_for_key(ov, "F5")
      assert :main in contexts
      assert Overrides.bindings_for_key(ov, "Ctrl-P") == []
      assert Overrides.bindings_for_key(ov, "nonsense") == []
    end
  end
end
