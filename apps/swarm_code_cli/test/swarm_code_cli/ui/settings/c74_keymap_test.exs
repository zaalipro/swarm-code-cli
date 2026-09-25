defmodule SwarmCodeCLI.UI.Settings.C74KeymapTest do
  @moduledoc """
  cli74 U1-2: the settings layer's keyboard grammar — F2 from the shell, the
  seven contexts, the letters only while browsing, and the override seam.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Input, Keymap, Size}
  alias SwarmCodeCLI.UI.Keymap.{Binding, Bindings, Context, KeyName, Overrides}
  alias SwarmCodeCLI.UI.Settings.{Confirm, Layer, Paste, Picker}

  @size %Size{columns: 160, rows: 45}

  defp shell(focus) do
    state = Fixtures.representative(:swarm, @size, %Capabilities{size: @size})
    %{state | focus: focus, layers: []}
  end

  defp open(layer \\ Layer.new(1), focus \\ "composer"),
    do: %{shell(focus) | settings: layer}

  defp press(state, code, mods \\ [])

  defp press(state, code, mods) when is_binary(code),
    do: Keymap.resolve(Input.text_fragment(:press, code, mods), state, %{})

  defp press(state, code, mods), do: Keymap.resolve(Input.key(:press, code, mods), state, %{})

  defp settings_bindings,
    do: Enum.filter(Bindings.all(), &(&1.group == :settings or &1.id == :settings_open))

  describe "opening" do
    test "F2 opens Settings from the transcript, the composer, vim NORMAL and the inspector" do
      for focus <- ["main", "composer", "inspector"] do
        assert press(shell(focus), {:function, 2}) == {:ok, {:settings_open, nil}}, focus
      end

      normal = %{shell("composer") | keymap: :vim, vim: %SwarmCodeCLI.UI.Vim{mode: :normal}}
      assert Context.of(normal) == :composer_normal
      assert press(normal, {:function, 2}) == {:ok, {:settings_open, nil}}
    end

    test "F2 again, q and Esc leave; Esc goes back one level first" do
      state = open()
      assert press(state, {:function, 2}) == {:ok, {:settings, {:verb, :close}}}
      assert press(state, "q") == {:ok, {:settings, {:verb, :close}}}
      assert press(state, :escape) == {:ok, {:settings, {:verb, :back}}}
    end

    test "no binding anywhere is Ctrl-K, and every settings binding has a key without Alt" do
      for binding <- Bindings.all(), {code, mods} <- binding.keys do
        refute code in ["k", "K"] and :control in mods, "#{binding.id} binds Ctrl-K"
      end

      for binding <- settings_bindings() do
        assert Enum.any?(binding.keys, fn {_code, mods} -> :alt not in mods end),
               "#{binding.id} is Alt-only"
      end
    end

    test "the action vocabulary accepts the open arguments and refuses the rest" do
      assert {:ok, _} = SwarmCodeCLI.UI.Action.validate({:settings_open, "theme"})
      assert {:ok, _} = SwarmCodeCLI.UI.Action.validate({:settings_open, {:section, :mcp}})

      assert {:ok, _} =
               SwarmCodeCLI.UI.Action.validate({:settings_open, {:key, "terminal.theme"}})

      assert {:error, _} = SwarmCodeCLI.UI.Action.validate({:settings_open, {:section, :nope}})

      assert {:error, _} =
               SwarmCodeCLI.UI.Action.validate({:settings_open, String.duplicate("a", 201)})

      assert {:error, _} = SwarmCodeCLI.UI.Action.validate({:settings, {:verb, :explode}})
      assert {:error, _} = SwarmCodeCLI.UI.Action.validate({:settings, {:text, "\e[2J"}})
    end
  end

  describe "the table" do
    test "one binding per key and context in the settings contexts" do
      pairs =
        for binding <- Bindings.all(),
            context <- Bindings.settings_contexts(),
            key <- Bindings.keys_in_context(binding, context),
            do: {{context, key}, binding.id}

      duplicates =
        pairs
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.filter(fn {_, ids} -> length(ids) > 1 end)

      assert duplicates == []

      claimed =
        for binding <- settings_bindings(),
            {code, mods} = key <- binding.keys,
            context <- binding.contexts,
            context in Bindings.settings_contexts(),
            not (is_binary(code) and mods == [] and context != :settings),
            uniq: true,
            do: {context, key}

      assert length(claimed) == length(Enum.uniq(Enum.map(pairs, &elem(&1, 0))))
    end

    test "every settings letter is bound only while browsing" do
      for binding <- settings_bindings(),
          {code, []} <- binding.keys,
          is_binary(code),
          context <- Bindings.settings_contexts() -- [:settings] do
        assert Bindings.lookup(context, code, []) == nil,
               "#{binding.id}'s #{inspect(code)} is bound in #{context}"
      end

      letters = ~w(a x X D J K t f o e n c C N A u U y g r R s i + / : q [ ])

      for letter <- letters do
        assert %Binding{group: :settings} = Bindings.lookup(:settings, letter, []), letter
      end
    end

    test "global bindings never reach the settings contexts" do
      for context <- Bindings.settings_contexts(),
          binding <- Bindings.for_context(context) do
        assert binding.group == :settings, "#{binding.id} leaks into #{context}"
      end

      assert press(open(), "p", [:control]) == :ignore
      assert press(open(), "g", [:control]) == :ignore
      assert press(open(), "?") == {:ok, {:settings, {:verb, :help}}}
    end

    test "every context has its keys documented" do
      for context <- Bindings.settings_contexts() do
        assert SwarmCodeCLI.UI.Keymap.Docs.title(context) =~ "Settings"
      end

      docs = SwarmCodeCLI.UI.Keymap.Docs.render()
      assert docs =~ "# Settings"
      assert docs =~ "swarmcode config reset"
      assert docs =~ "`F2`"
    end
  end

  describe "the contexts" do
    test "the mode and popover pick the context; typing never reaches the composer" do
      assert Context.of(open()) == :settings
      assert Context.of(open(%{Layer.new(1) | mode: :search})) == :settings_search
      assert Context.of(open(%{Layer.new(1) | mode: :editing, editing: %{}})) == :settings_edit

      assert Context.of(open(%{Layer.new(1) | mode: :paste, paste: Paste.new(%{})})) ==
               :settings_paste

      assert Context.of(open(%{Layer.new(1) | mode: :capture})) == :settings_capture
      assert Context.of(open(%{Layer.new(1) | popover: {:picker, %Picker{}}})) == :settings_picker

      assert Context.of(open(%{Layer.new(1) | popover: {:confirm, %Confirm{}}})) ==
               :settings_popover

      refute Keymap.typing?(Input.text_fragment(:press, "a", []), open())
      assert Keymap.editor_context(open()) == nil
    end

    test "browsing: letters are verbs, arrows move, Tab walks the regions" do
      state = open()
      assert press(state, "a") == {:ok, {:settings, {:verb, :add}}}
      assert press(state, "x") == {:ok, {:settings, {:verb, :delete}}}
      assert press(state, :delete) == {:ok, {:settings, {:verb, :delete}}}
      assert press(state, "D") == {:ok, {:settings, {:verb, :delete_record}}}
      assert press(state, " ") == {:ok, {:settings, {:verb, :toggle}}}
      assert press(state, :down) == {:ok, {:settings, {:verb, :down}}}
      assert press(state, :right, [:shift]) == {:ok, {:settings, {:verb, :big_right}}}
      assert press(state, :up, [:shift]) == {:ok, {:settings, {:verb, :move_up}}}
      assert press(state, :tab) == {:ok, {:settings, {:verb, :next_region}}}
      assert press(state, :back_tab) == {:ok, {:settings, {:verb, :previous_region}}}
      assert press(state, "z", [:control]) == {:ok, {:settings, {:verb, :undo}}}
      assert press(state, "y", [:control]) == {:ok, {:settings, {:verb, :redo}}}
      assert press(state, "c", [:control]) == {:ok, {:settings, {:verb, :interrupt}}}
      assert press(state, "j") == :ignore
    end

    test "vim's j, k and G move while browsing, never while typing" do
      vim = fn layer -> %{open(layer) | keymap: :vim} end
      assert press(vim.(Layer.new(1)), "j") == {:ok, {:settings, {:verb, :down}}}
      assert press(vim.(Layer.new(1)), "k") == {:ok, {:settings, {:verb, :up}}}
      assert press(vim.(Layer.new(1)), "G") == {:ok, {:settings, {:verb, :last}}}
      assert press(vim.(Layer.new(1)), "g") == {:ok, {:settings, {:verb, :goto}}}

      assert press(vim.(%{Layer.new(1) | mode: :search}), "j") ==
               {:ok, {:settings, {:text, "j"}}}
    end

    test "search and editors type; their keys are verbs or editor keys" do
      search = open(%{Layer.new(1) | mode: :search})
      assert press(search, "q") == {:ok, {:settings, {:text, "q"}}}
      assert press(search, "?") == {:ok, {:settings, {:text, "?"}}}
      assert press(search, :escape) == {:ok, {:settings, {:verb, :escape}}}
      assert press(search, :enter) == {:ok, {:settings, {:verb, :enter}}}
      assert press(search, {:function, 1}) == {:ok, {:settings, {:verb, :help}}}

      edit = open(%{Layer.new(1) | mode: :editing, editing: %{}})
      assert press(edit, "x") == {:ok, {:settings, {:text, "x"}}}
      assert press(edit, :enter) == {:ok, {:settings, {:verb, :commit}}}
      assert press(edit, :backspace) == {:ok, {:settings, {:verb, :backspace}}}
      assert press(edit, "u", [:control]) == {:ok, {:settings, {:verb, :clear_line}}}
      assert press(edit, "s", [:control]) == {:ok, {:settings, {:verb, :save}}}

      assert press(edit, :insert) == {:ok, {:settings, {:key, :insert}}} or
               press(edit, :insert) == :ignore
    end

    test "a paste goes to the layer, never to the draft beneath" do
      paste = open(%{Layer.new(1) | mode: :paste, paste: Paste.new(%{})})
      canary = "sk-canary-7Q2X-DO-NOT-SHOW"

      assert Keymap.resolve(Input.paste(canary), paste, %{}) ==
               {:ok, {:settings, {:paste, canary}}}

      assert press(paste, "t", [:control]) == {:ok, {:settings, {:verb, :paste_type}}}
      assert press(paste, "u", [:control]) == {:ok, {:settings, {:verb, :paste_clear}}}
      assert press(paste, :enter) == {:ok, {:settings, {:verb, :paste_commit}}}
      assert press(paste, "k") == {:ok, {:settings, {:text, "k"}}}

      assert Keymap.resolve(Input.paste("hello"), open(), %{}) ==
               {:ok, {:settings, {:paste, "hello"}}}
    end

    test "key capture takes every chord as data except Ctrl-C" do
      capture = open(%{Layer.new(1) | mode: :capture})
      assert press(capture, "j", [:control]) == {:ok, {:settings, {:raw, {"j", [:control]}}}}
      assert press(capture, :escape) == {:ok, {:settings, {:raw, {:escape, []}}}}
      assert press(capture, "x") == {:ok, {:settings, {:raw, {"x", []}}}}
      assert press(capture, "c", [:control]) == {:ok, {:settings, {:verb, :interrupt}}}
    end

    test "Ctrl-F badges take the next key" do
      jump = open(%{Layer.new(1) | jump: %{labels: %{}}})

      assert press(Map.put(open(), :settings, Layer.new(1)), "f", [:control]) ==
               {:ok, {:settings, {:verb, :jump}}}

      assert press(jump, "b") == {:ok, {:settings, {:raw, {"b", []}}}}
      assert press(jump, :escape) == {:ok, {:settings, {:raw, {:escape, []}}}}
      assert press(jump, "c", [:control]) == {:ok, {:settings, {:verb, :interrupt}}}
    end

    test "popovers: buttons by Tab, letters fall through as text" do
      popover = open(%{Layer.new(1) | popover: {:confirm, %Confirm{}}})
      assert press(popover, :tab) == {:ok, {:settings, {:verb, :next_button}}}
      assert press(popover, :back_tab) == {:ok, {:settings, {:verb, :previous_button}}}
      assert press(popover, "D") == {:ok, {:settings, {:text, "D"}}}
      assert press(popover, :escape) == {:ok, {:settings, {:verb, :escape}}}

      picker = open(%{Layer.new(1) | popover: {:picker, %Picker{}}})
      assert press(picker, "o") == {:ok, {:settings, {:text, "o"}}}
      assert press(picker, :down) == {:ok, {:settings, {:verb, :down}}}
    end

    test "the wheel scrolls the layer" do
      wheel = {:mouse, :wheel_down, nil, 10, 5, []}
      assert Keymap.resolve(wheel, open(), %{}) == {:ok, {:settings, {:wheel, 3, 10, 5}}}
    end
  end

  describe "overrides and key names (the seam U3 fills)" do
    # pass74 U3-2: the overrides are real now (U3 owns overrides.ex after
    # c74-U1-api): an override moves the binding, its default key is unbound.
    test "an override moves a binding and unbinds its default key" do
      overrides = Overrides.compile(%{"settings_add" => ["b"]})
      assert overrides.errors == []
      assert Overrides.lookup(overrides, :settings, "a", []) == :unbound
      assert Overrides.keys_for(overrides, :settings_add) == [{"b", []}]
      assert Overrides.check(overrides, "settings_add", ["b"]) == :ok
      assert Bindings.lookup(:settings, "b", [], overrides).id == :settings_add
      assert Bindings.lookup(:settings, "a", [], overrides) == nil
      assert Bindings.keys_for(:settings_add, overrides) == [{"b", []}]
      binding = Bindings.fetch(:settings_add)
      assert Bindings.key_in_context(binding, :settings, overrides) == {"b", []}

      reached = Overrides.bindings_for_key(overrides, "b")
      assert Enum.any?(reached, &match?({%Binding{id: :settings_add}, [:settings]}, &1))
      assert Enum.all?(reached, fn {_binding, contexts} -> contexts != [] end)

      ids = overrides |> Overrides.bindings_for_key("Ctrl-C") |> Enum.map(&elem(&1, 0).id)
      assert :interrupt in ids and :settings_interrupt in ids
    end

    test "an override table changes what a key reaches" do
      add = Bindings.fetch(:settings_add)

      overrides = %Overrides{
        table: %{{:settings, {"b", []}} => add},
        removed: MapSet.new([{:settings, {"a", []}}]),
        by_id: %{settings_add: [{"b", []}]}
      }

      state = %{open() | key_overrides: overrides}
      assert press(state, "b") == {:ok, {:settings, {:verb, :add}}}
      assert press(state, "a") == :ignore
      assert Bindings.key_in_context(add, :settings, overrides) == {"b", []}
    end

    test "key names parse and print in the stored form" do
      assert KeyName.parse("Ctrl-L") == {:ok, {"l", [:control]}}
      assert KeyName.parse("ctrl-shift-z") == {:ok, {"z", [:control, :shift]}}
      assert KeyName.parse("X") == {:ok, {"X", []}}
      assert KeyName.parse("Shift-Tab") == {:ok, {:back_tab, []}}
      assert KeyName.parse("PageDown") == {:ok, {:page_down, []}}
      assert KeyName.parse("F5") == {:ok, {{:function, 5}, []}}
      assert KeyName.parse("Space") == {:ok, {" ", []}}
      assert KeyName.parse("?") == {:ok, {"?", []}}
      assert {:error, _} = KeyName.parse("Shift-x")
      assert {:error, _} = KeyName.parse("F13")
      assert {:error, _} = KeyName.parse("Hyper-Q")

      for name <- [
            "Ctrl-L",
            "Alt-Enter",
            "Shift-Tab",
            "F5",
            "PageDown",
            "x",
            "X",
            "?",
            "Space",
            "Up"
          ] do
        {:ok, key} = KeyName.parse(name)
        assert KeyName.format(key, :stored) == name
      end

      assert KeyName.format({:up, []}, :rich) == "↑"
      assert KeyName.format({:up, []}, :ascii) == "Up"
    end
  end
end
