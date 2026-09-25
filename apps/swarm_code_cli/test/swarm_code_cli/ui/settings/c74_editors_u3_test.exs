defmodule SwarmCodeCLI.UI.Settings.C74EditorsU3Test do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Keymap.Overrides
  alias SwarmCodeCLI.UI.Settings.Editors.{Color, KeyCapture}

  defp ctx(keys \\ %{}, now \\ 0) do
    %{prefs: %{"keys" => keys}, overrides: Overrides.compile(keys), now: now, caps: nil}
  end

  defp row, do: %{label: "Palette", key: "terminal.keys"}

  describe "KeyCapture, binding mode" do
    test "capture of Ctrl-L writes [\"Ctrl-L\"] in the keys map" do
      {:ok, state} = KeyCapture.init(row(), %{mode: :binding, binding: "command_palette"}, ctx())
      assert %{context: :settings_capture} = KeyCapture.display(state, ctx())

      assert {:commit, %{"command_palette" => ["Ctrl-L"]}, _} =
               KeyCapture.handle(state, {:raw, {"l", [:control]}}, ctx())
    end

    test "+ then F6 adds a key to the ones in force" do
      keys = %{"command_palette" => ["F7"]}
      c = ctx(keys)

      {:ok, state} =
        KeyCapture.init(row(), %{mode: :binding, binding: "command_palette", add?: true}, c)

      assert {:commit, %{"command_palette" => ["F7", "F6"]}, _} =
               KeyCapture.handle(state, {:raw, {{:function, 6}, []}}, c)
    end

    test "a taken key stops the capture and offers swap and replace; swap writes both" do
      {:ok, state} = KeyCapture.init(row(), %{mode: :binding, binding: "command_palette"}, ctx())
      assert {:cont, taken} = KeyCapture.handle(state, {:raw, {"g", [:control]}}, ctx())
      assert taken.phase == :taken
      assert taken.message =~ ~s(Ctrl-G is taken by "Runs")

      display = KeyCapture.display(taken, ctx())
      assert display.context == :settings_popover
      assert {"s", "swap"} in display.footer

      assert {:commit, swapped, _} = KeyCapture.handle(taken, {:text, "s"}, ctx())
      assert swapped == %{"command_palette" => ["Ctrl-G"], "runs_dashboard" => ["Ctrl-P"]}
      assert Overrides.compile(swapped).errors == []

      assert {:commit, replaced, _} = KeyCapture.handle(taken, {:text, "r"}, ctx())
      assert replaced == %{"command_palette" => ["Ctrl-G"], "runs_dashboard" => []}

      assert {:cont, %{phase: :capture}} = KeyCapture.handle(taken, {:text, "k"}, ctx())
      assert {:cancel, _} = KeyCapture.handle(taken, {:key, :escape}, ctx())
    end

    test "unknown entries already in cli.json are kept by a swap" do
      keys = %{"x-mine" => ["F9"]}

      {:ok, state} =
        KeyCapture.init(row(), %{mode: :binding, binding: "command_palette"}, ctx(keys))

      {:cont, taken} = KeyCapture.handle(state, {:raw, {"g", [:control]}}, ctx(keys))

      assert {:commit, %{"x-mine" => ["F9"]}, _} =
               KeyCapture.handle(taken, {:text, "s"}, ctx(keys))
    end

    test "fixed and unreportable keys are refused with k and Esc" do
      {:ok, state} = KeyCapture.init(row(), %{mode: :binding, binding: "command_palette"}, ctx())
      assert {:cont, refused} = KeyCapture.handle(state, {:raw, {"s", [:control]}}, ctx())
      assert refused.phase == :refused
      assert refused.message == "Ctrl-S is fixed"
      assert {:cont, %{phase: :capture}} = KeyCapture.handle(refused, {:text, "k"}, ctx())
    end

    test "Esc once is captured and refused; Esc twice within 1.5 s cancels" do
      {:ok, state} = KeyCapture.init(row(), %{mode: :binding, binding: "command_palette"}, ctx())
      assert {:cont, once} = KeyCapture.handle(state, {:raw, {:escape, []}}, ctx(%{}, 1_000))
      assert once.message =~ "Esc is fixed"
      assert {:cancel, _} = KeyCapture.handle(once, {:raw, {:escape, []}}, ctx(%{}, 2_400))
      assert {:cont, _} = KeyCapture.handle(once, {:raw, {:escape, []}}, ctx(%{}, 2_600))
    end

    test "fixed bindings and full bindings cannot open the capture" do
      assert {:error, _} = KeyCapture.init(row(), %{mode: :binding, binding: "help"}, ctx())

      keys = %{"command_palette" => ["F5", "F6", "F7", "F8"]}

      assert {:error, "4 keys at most"} =
               KeyCapture.init(
                 row(),
                 %{mode: :binding, binding: "command_palette", add?: true},
                 ctx(keys)
               )
    end
  end

  describe "KeyCapture, desktop mode" do
    test "a chord becomes the desktop's combo" do
      {:ok, state} = KeyCapture.init(row(), %{mode: :desktop, action: "side"}, ctx())

      assert {:commit, "ctrl+shift+s", _} =
               KeyCapture.handle(state, {:raw, {"S", [:control]}}, ctx())

      assert {:commit, "shift+alt+ArrowLeft", _} =
               KeyCapture.handle(state, {:raw, {:left, [:alt, :shift]}}, ctx())

      assert {:commit, "Escape", _} = KeyCapture.handle(state, {:raw, {:escape, []}}, ctx())
    end

    test "a bare key needs a modifier; t types a combo instead" do
      {:ok, state} = KeyCapture.init(row(), %{mode: :desktop, action: "side"}, ctx())
      assert {:cont, refused} = KeyCapture.handle(state, {:raw, {"p", []}}, ctx())
      assert refused.phase == :refused
      assert {:cont, typing} = KeyCapture.handle(refused, {:text, "t"}, ctx())
      {:cont, typing} = KeyCapture.handle(typing, {:text, "meta+shift+s"}, ctx())
      assert {:commit, "meta+shift+s", _} = KeyCapture.handle(typing, {:key, :enter}, ctx())

      {:cont, bad} = KeyCapture.handle(%{typing | typed: "hyper+x"}, {:key, :enter}, ctx())
      assert bad.message == "invalid key combo"
    end

    test "combo?/1 is the desktop's grammar" do
      assert KeyCapture.combo?("meta+,")
      assert KeyCapture.combo?("shift+alt+ArrowRight")
      assert KeyCapture.combo?("Escape")
      refute KeyCapture.combo?("p")
      refute KeyCapture.combo?("meta+Enter")
    end
  end

  describe "Color" do
    test "typing hex commits upper-case #RRGGBB; #RGB expands" do
      {:ok, state} = Color.init(%{}, %{}, %{prefs: %{}})
      {:cont, state} = Color.handle(state, {:text, "#2dd4bf"}, nil)
      assert {:commit, "#2DD4BF", _} = Color.handle(state, {:key, :enter}, nil)

      {:ok, state} = Color.init(%{}, %{}, %{prefs: %{}})
      {:cont, state} = Color.handle(state, {:text, "f60"}, nil)
      assert {:commit, "#FF6600", _} = Color.handle(state, {:key, :enter}, nil)
    end

    test "a bad colour stays with the message; empty stores nothing" do
      {:ok, state} = Color.init(%{}, %{}, %{prefs: %{"accent" => "#112233"}})
      assert state.text == "#112233"
      {:cont, state} = Color.handle(state, {:key, {:ctrl, "u"}}, nil)
      assert {:commit, nil, _} = Color.handle(state, {:key, :enter}, nil)

      {:cont, state} = Color.handle(state, {:text, "orange"}, nil)

      assert {:cont, %{message: "a colour such as #FF6A1A"}} =
               Color.handle(state, {:key, :enter}, nil)
    end

    test "the lines show twins and contrast; low contrast warns" do
      {:ok, state} = Color.init(%{}, %{}, %{prefs: %{}})
      {:cont, state} = Color.handle(state, {:text, "#FF6A1A"}, nil)
      display = Color.display(state, %{caps: %{ascii?: false}})
      text = display.lines |> List.flatten() |> Enum.map_join(&elem(&1, 0))
      assert text =~ "256: 202 · 16: bright red"
      assert text =~ "on the page"
      assert text =~ "✓"

      {:cont, dark} = Color.handle(%{state | text: ""}, {:text, "#202020"}, nil)
      segments = Color.display(dark, nil).lines |> List.flatten()

      assert Enum.any?(segments, fn {text, role} ->
               role == :warning and text =~ "hard to read"
             end)

      assert Enum.any?(segments, fn {text, _} -> text == "applies at the next launch" end)
    end

    test "value segments: swatch of the launch accent, the ASCII twin otherwise" do
      assert [{"██", :accent}, {" #FF6A1A · Carbon", _}] = Color.value_segments(nil, nil)
      assert [{"[#2DD4BF]", _}, {" #2DD4BF", _}] = Color.value_segments("#2DD4BF", nil)

      assert [{"[#FF6A1A]", _} | _] =
               Color.value_segments("#FF6A1A", %{caps: %{ascii?: true}})
    end
  end
end
