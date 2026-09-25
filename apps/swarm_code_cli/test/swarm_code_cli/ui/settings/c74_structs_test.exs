defmodule SwarmCodeCLI.UI.Settings.C74StructsTest do
  @missing SwarmCodeCLI.UI.Settings.Sections.NotInThisBuild
  @compile {:no_warn_undefined, @missing}

  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Settings

  alias SwarmCodeCLI.UI.Settings.{
    Attention,
    Confirm,
    Ctx,
    Data,
    Editor,
    Glyphs,
    Layer,
    Op,
    Page,
    Paste,
    Picker,
    Row,
    Section,
    Sections,
    Undo
  }

  @canary "sk-canary-7Q2X-DO-NOT-SHOW"

  describe "Layer" do
    test "inspect never shows the paste or the drafts" do
      paste = Paste.new(%{kind: "provider", id: "p1", slot: "api_key"}) |> Paste.put(@canary)

      layer = %{
        Layer.new(3)
        | paste: paste,
          drafts: %{"provider" => %{fields: %{"name" => "x"}, secrets: %{"api_key" => @canary}}}
      }

      text = inspect(layer, limit: :infinity, printable_limit: :infinity)
      refute text =~ @canary
      refute text =~ "7Q2X"
      assert text =~ "generation: 3"
    end

    test "a new layer opens on the Overview; push and pop move one level" do
      layer = Layer.new(1)
      assert Layer.section(layer) == :overview
      assert Layer.pop(layer) == :top

      record = %Page{section: :providers, record: {"provider", "p1"}}
      layer = layer |> Layer.put_page(Page.section(:providers)) |> Layer.push(record)
      assert Layer.depth(layer) == 2
      assert Page.level(Layer.page(layer)) == :record
      assert {:ok, back} = Layer.pop(layer)
      assert Layer.section(back) == :providers
      assert Page.level(Layer.page(back)) == :section
    end

    test "the keymap context follows the popover, then the mode" do
      layer = Layer.new(1)
      assert Settings.context(layer) == :settings
      assert Settings.context(%{layer | mode: :search}) == :settings_search
      assert Settings.context(%{layer | mode: :command_line}) == :settings_search
      assert Settings.context(%{layer | mode: :paste}) == :settings_paste
      assert Settings.context(%{layer | mode: :capture}) == :settings_capture
      assert Settings.context(%{layer | mode: :editing, editing: %{}}) == :settings_edit

      assert Settings.context(%{layer | mode: :editing, editing: %{context: :settings}}) ==
               :settings

      assert Settings.context(%{layer | popover: {:picker, %Picker{}}}) == :settings_picker
      assert Settings.context(%{layer | popover: {:confirm, %Confirm{}}}) == :settings_popover

      assert Settings.context(%{layer | mode: :editing, popover: {:help, nil}}) ==
               :settings_popover

      assert length(Settings.contexts()) == 7
      assert Settings.open?(%{settings: layer})
      refute Settings.open?(%{settings: nil})
    end
  end

  describe "Paste" do
    test "inspect shows the target and the line count, never the bytes" do
      paste = Paste.new(%{slot: "api_key"}) |> Paste.put(@canary)
      text = inspect(paste)
      refute text =~ @canary
      assert text =~ "lines: 1"
    end

    test "check refuses what cannot be a key, with the words the row shows" do
      check = fn bytes -> Paste.check(Paste.put(Paste.new(%{}), bytes)) end

      assert check.("") == {:error, "paste the key first"}

      assert check.("line-one-key\nline-two-key") ==
               {:error, "the paste had 2 lines; paste only the key"}

      assert check.("sk-abc def123") == {:error, "a key has no spaces inside"}
      assert check.("short") == {:error, "that is too short to be a key"}
      assert check.(String.duplicate("a", 8193)) == {:error, "that is too long to be a key"}
      assert check.("  #{@canary}\n") == {:ok, @canary}
    end

    test "typing appends and Ctrl-U clears" do
      paste = Paste.new(%{}) |> Paste.type("abc") |> Paste.type("def")
      assert Paste.filled?(paste)
      refute paste |> Paste.clear() |> Paste.filled?()
    end
  end

  describe "Undo" do
    test "past and future are bounded; a new step clears the future" do
      undo = Enum.reduce(1..120, %Undo{}, &Undo.push(&2, %{n: &1}))
      assert length(undo.past) == 100
      assert {%{n: 120}, undo} = Undo.pop(undo)
      assert Undo.redo?(undo)
      undo = Undo.push(undo, %{n: 121})
      refute Undo.redo?(undo)
      assert Undo.pop(%Undo{}) == :empty
    end

    test "the changelog keeps the newest 200 entries" do
      undo = Enum.reduce(1..230, %Undo{}, &Undo.log(&2, &1, "change #{&1}"))
      assert length(undo.changelog) == 200
      assert hd(undo.changelog).text == "change 230"
    end
  end

  describe "Sections" do
    test "module_for covers the 22 sections in rail order" do
      ids = Sections.ids()
      assert length(ids) == 22
      assert hd(ids) == :overview
      assert Enum.uniq(ids) == ids

      for id <- ids do
        module = Sections.module_for(id)
        assert is_atom(module)
        assert "Elixir.SwarmCodeCLI.UI.Settings.Sections." <> _ = Atom.to_string(module)
      end

      assert_raise FunctionClauseError, fn -> Sections.module_for(:nope) end
    end

    test "groups follow the rail: overview, models, tools, agents, this terminal, data, more" do
      assert Enum.map(Sections.groups(), &elem(&1, 0)) ==
               [nil, "models", "tools", "agents", "this terminal", "data", "more"]
    end

    test "fetch folds case, spaces and punctuation and knows synonyms" do
      assert Sections.fetch("MCP") == {:ok, :mcp}
      assert Sections.fetch("search") == {:ok, :search_web}
      assert Sections.fetch("Models & effort") == {:ok, :models_effort}
      assert Sections.fetch("keybindings") == {:ok, :keys}
      assert Sections.fetch("language-servers") == {:ok, :language_servers}
      assert Sections.fetch("theme") == :error
    end

    test "step wraps around the rail" do
      assert Sections.step(:overview, -1) == :import_export
      assert Sections.step(:import_export, 1) == :overview
      assert Sections.step(:overview, 1) == :models_effort
    end

    test "a section that is not in this build falls back to the defaults" do
      # Every section is built on the merged tree; the fallback itself is
      # `Sections.optional/3`, which answers nil only for the missing module
      # and callback it names and re-raises anything else.
      for %{id: id} <- Sections.all(),
          do: assert(Code.ensure_loaded?(Sections.module_for(id)), "#{id}")

      assert Sections.optional(@missing, :act, fn -> @missing.act(%Ctx{}, %Row{}, :enter) end) ==
               nil

      assert_raise UndefinedFunctionError, fn ->
        Sections.optional(Sections.Library, :act, fn -> @missing.act(%Ctx{}, %Row{}, :enter) end)
      end
    end
  end

  describe "use Section" do
    defmodule Demo do
      use SwarmCodeCLI.UI.Settings.Section, id: :storage

      @impl true
      def act(_ctx, %Row{id: "act:clean"}, :enter), do: [{:toast, "cleaned", :success}]
      def act(_ctx, _row, _action), do: :default
    end

    test "injects the defaults and keeps overrides" do
      ctx = %Ctx{}
      assert Demo.id() == :storage
      assert Demo.loads(ctx) == [{:values, [:storage]}]
      assert Demo.title(ctx) == "Storage"
      assert Demo.act(ctx, %Row{id: "act:clean"}, :enter) == [{:toast, "cleaned", :success}]
      assert Demo.act(ctx, %Row{id: "other"}, :enter) == :default
      assert Demo.counts(ctx) == %{records: nil}
      assert Section.default_loads(:overview, ctx) == [:overview]
    end
  end

  describe "Op" do
    test "valid? accepts the vocabulary and refuses anything else" do
      ops = [
        {:patch, "limits.max_concurrent_agents", 4},
        {:reset, ["limits.max_concurrent_agents"]},
        {:reset_section, :agents_limits},
        Op.command("record.update", %{kind: "provider", id: "p"}, %{"name" => "x"}),
        {:task, "provider.test", %{id: "p"}, %{}},
        {:cancel_task, "t1"},
        {:load, {:values, [:mcp]}},
        {:open, Page.section(:mcp)},
        :back,
        {:section, :mcp},
        {:confirm, %Confirm{id: "c"}, then: [:back]},
        {:picker, %Picker{id: "p"}},
        {:paste, %{slot: "api_key"}},
        {:edit, "key:x.y"},
        {:external_edit, %{ref: "r"}},
        {:cli_write, %{"theme" => "carbon"}},
        {:open_folder, "/tmp"},
        {:copy, "text"},
        {:toast, "Saved", :success},
        {:leave, :close}
      ]

      for op <- ops, do: assert(Op.valid?(op), inspect(op))
      # An empty change set is the "Make it private" rewrite (U3's request).
      assert Op.valid?({:cli_write, %{}})
      refute Op.valid?({:cli_write, [:panel]})
      refute Op.valid?({:patch, :atom, 1})
      refute Op.valid?(:nonsense)
    end
  end

  describe "Row, Picker, Attention, Data" do
    test "headings and blank info rows are not focusable" do
      refute Row.focusable?(Row.heading("limits"))
      refute Row.focusable?(Row.info("empty", "nothing here"))
      assert Row.focusable?(Row.info("link", "open", target: :x))
      assert Row.focusable?(%Row{id: "key:a.b", kind: :setting})
    end

    test "the picker filters by word prefixes" do
      picker = %Picker{
        options: [
          %{value: "a", label: "Claude Opus", hint: "anthropic"},
          %{value: "b", label: "DeepSeek V4 Pro", hint: nil}
        ]
      }

      assert [%{value: "b"}] = Picker.visible(%{picker | query: "deep pro"})
      assert [%{value: "a"}] = Picker.visible(%{picker | query: "anthr"})
      assert length(Picker.visible(picker)) == 2
    end

    test "attention sorts errors first, then rail order" do
      items = [
        %Attention{id: "w", severity: :warning, section: :mcp},
        %Attention{id: "e2", severity: :error, section: :storage},
        %Attention{id: "e1", severity: :error, section: :providers}
      ]

      assert Enum.map(Attention.sort(items, Sections.order()), & &1.id) == ["e1", "e2", "w"]
    end

    test "record pages are bounded per kind" do
      data =
        Enum.reduce(1..12, %Data{}, fn n, data ->
          Data.put_records(data, {"mcp_server", %{cursor: n}}, %{items: []}, n)
        end)

      assert map_size(data.records) == Data.bounds().record_pages_per_kind
    end
  end

  describe "Glyphs" do
    test "every glyph has an ASCII twin and the ASCII tier draws ASCII only" do
      for id <- Glyphs.ids() do
        ascii = Glyphs.get(id, :ascii)
        assert ascii == Glyphs.asciify(ascii)
        assert String.match?(ascii, ~r/\A[\x20-\x7e]*\z/), inspect(id)
      end

      assert Glyphs.for_caps(:crumb, %{ascii?: true}) == ">"
      assert Glyphs.for_caps(:crumb, %{glyph_tier: :measured, ambiguous_width: :narrow}) == "›"
      assert Glyphs.asciify("Models › Providers · ✓ ok") == "Models > Providers - v ok"
    end
  end

  describe "Editor" do
    test "event? knows the editor events" do
      assert Editor.event?({:key, :enter})
      assert Editor.event?({:key, {:ctrl, "u"}})
      assert Editor.event?({:key, {:shift, :left}})
      assert Editor.event?({:text, "a"})
      assert Editor.event?(:tick)
      refute Editor.event?({:key, :weird})
      refute Editor.event?({:text, ""})
    end
  end
end
