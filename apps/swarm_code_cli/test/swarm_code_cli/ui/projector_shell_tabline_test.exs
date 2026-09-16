defmodule SwarmCodeCLI.UI.ProjectorShellTablineTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, SafeText, Size, Theme, Width}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Blocks, Options}
  alias SwarmCodeCLI.UI.Projector.{Shell, Support}

  @hint "Ctrl-R runs   Ctrl-G all   Ctrl-P features"

  # A tab is stripe, gap, mark, gap, title, gap, dot, gap: eight spans whose
  # title sits at offset 4.
  @stripe 0
  @mark 2
  @title 4
  @dot 6
  @tab_span_count 8

  # `struct/2` drops the keys that are not capability fields, so the same option
  # list carries both the fixture's shape and the terminal's capabilities.
  defp caps(opts), do: struct(%Capabilities{size: nil, color_mode: :truecolor}, opts)

  defp run(id, kind, opts) do
    %DTO.RunSummary{
      id: id,
      conversation_id: "conversation-#{id}",
      kind: kind,
      title: Keyword.get(opts, :title, "Run #{id}"),
      revision: 1,
      state: Keyword.get(opts, :state, :running),
      allowed_actions: [],
      progress: Keyword.get(opts, :progress, 40),
      created_sequence: Keyword.get(opts, :created_sequence, 0)
    }
  end

  # {id, wire kind, title, state, themed kind, status role}
  @fleet [
    {"swarm-1", :swarm, "Swarm auth", :running, :swarm, :accent},
    {"consensus-1", :consensus, "Review board", :failed, :consensus_judge, :error},
    {"research-1", :research, "Auth landscape", :done, :research, :success},
    {"workflow-1", :workflow, "Release checklist", :queued, :workflow, :warning},
    {"chat-1", :chat, "Assistant thread", :streaming, :assistant, :accent}
  ]

  defp populated(opts \\ []) do
    columns = Keyword.get(opts, :columns, 170)
    state = Fixtures.representative(:chat, %Size{columns: columns, rows: 40}, caps(opts))

    runs =
      @fleet
      |> Enum.with_index()
      |> Enum.map(fn {{id, kind, title, status, _themed, _role}, index} ->
        run(id, kind, title: title, state: status, created_sequence: length(@fleet) - index)
      end)

    state = put_in(state.read_model.runs, Map.new(runs, &{&1.id, &1}))
    %{state | destination: {:run, Keyword.get(opts, :active, "workflow-1")}}
  end

  defp painted(state, width, opts \\ []) do
    base = %{foreground: nil, background: nil, modifiers: []}

    options = %Options{
      color_mode: :truecolor,
      ascii?: Keyword.get(opts, :ascii?, false)
    }

    {:ok, lines} =
      Blocks.lines(
        [Shell.tabline(state, width)],
        width,
        options,
        base,
        200,
        Keyword.get(opts, :policy, :narrow)
      )

    Enum.map(lines, &Enum.map_join(&1.units, fn unit -> unit.text end))
  end

  defp spans(state, width), do: Shell.tabline(state, width).spans

  defp tab(state, width, title) do
    all = spans(state, width)
    index = Enum.find_index(all, &(SafeText.value(&1.text) == title))
    assert index, "no tab drawn for #{inspect(title)}"
    Enum.slice(all, (index - @title)..(index - @title + @tab_span_count - 1))
  end

  defp text(span), do: SafeText.value(span.text)
  defp hover(state), do: Theme.style(:hover, state.capabilities).background

  describe "the active tab" do
    test "the active run sits on the hover surface and carries the accent stripe" do
      state = populated(active: "workflow-1")
      tab = tab(state, 170, "Release checklist")

      assert text(Enum.at(tab, @stripe)) == SafeText.value(SafeText.chrome(:stripe))

      assert Enum.at(tab, @stripe).style.foreground ==
               Theme.style(:accent, state.capabilities).foreground

      surface = hover(state)
      assert surface

      for span <- tab do
        assert span.style.background == surface,
               "#{inspect(text(span))} was not painted on the hover surface"
      end
    end

    test "a run that is not active carries neither the stripe nor the hover surface" do
      state = populated(active: "workflow-1")
      tab = tab(state, 170, "Swarm auth")

      refute text(Enum.at(tab, @stripe)) == SafeText.value(SafeText.chrome(:stripe))
      assert text(Enum.at(tab, @stripe)) == " "

      for span <- tab do
        refute span.style.background == hover(state),
               "#{inspect(text(span))} borrowed the active tab's surface"
      end
    end

    test "the active run leads the row whatever its recency" do
      # chat-1 is the oldest run in the fleet, so recency alone would put it last.
      state = populated(active: "chat-1")

      assert [%{id: "chat-1"} | rest] = Shell.tabline_runs(state)
      assert Enum.map(rest, & &1.id) == ["swarm-1", "consensus-1", "research-1", "workflow-1"]

      row = state |> painted(170) |> hd()
      assert String.starts_with?(row, SafeText.value(SafeText.chrome(:stripe)) <> " ")

      assert String.contains?(row, "Assistant thread")
    end

    test "with no run destination every tab is inactive" do
      state = %{populated() | destination: :activity}

      refute Enum.any?(spans(state, 170), &(text(&1) == SafeText.value(SafeText.chrome(:stripe))))
      refute Enum.any?(spans(state, 170), &(&1.style.background == hover(state)))
    end
  end

  describe "kind and status colour" do
    test "the mark carries the kind colour and the dot the status colour" do
      # Each run takes its turn as the active one so that every kind in the
      # fleet is actually drawn, including the fifth, which otherwise overflows.
      for {id, _kind, title, status, themed, status_role} <- @fleet do
        state = populated(active: id)
        tab = tab(state, 170, title)
        mark = Enum.at(tab, @mark)
        dot = Enum.at(tab, @dot)

        {_letter, kind_role} = Theme.run_kind(themed)

        assert text(mark) == SafeText.value(SafeText.chrome(Theme.run_mark(themed))),
               "#{title} did not lead with its kind mark"

        assert mark.style.foreground == Theme.style(kind_role, state.capabilities).foreground,
               "#{title} mark did not carry #{kind_role}"

        assert text(dot) == SafeText.value(SafeText.chrome(:dot))

        assert {_word, ^status_role} = Theme.status(status)

        assert dot.style.foreground == Theme.style(status_role, state.capabilities).foreground,
               "#{title} dot did not carry #{status_role}"
      end
    end

    test "the marks and the dot are drawn without the role's own prefix cue" do
      state = populated()

      # Paint resolves a span prefix as `style.prefix || themed.prefix`, so a
      # run_* or status role here would reprint the single kind letter and the
      # status marker beside the glyph.
      for span <- spans(state, 170) do
        assert span.style.role == :plain
        assert span.style.prefix == nil
        assert span.style.cues == []
      end
    end

    test "the wire kinds :chat and :consensus reach the theme translated" do
      # Theme.run_kind/1 has no :chat or :consensus clause; an untranslated kind
      # would raise a FunctionClauseError while the row was being built.
      chat = populated(active: "chat-1")
      state = populated()

      assert text(Enum.at(tab(chat, 170, "Assistant thread"), @mark)) ==
               SafeText.value(SafeText.chrome(Theme.run_mark(:assistant)))

      assert text(Enum.at(tab(state, 170, "Review board"), @mark)) ==
               SafeText.value(SafeText.chrome(Theme.run_mark(:consensus_judge)))
    end

    test "a status change moves the dot's colour with it" do
      state = populated()
      before = Enum.at(tab(state, 170, "Swarm auth"), @dot).style.foreground

      state = put_in(state.read_model.runs["swarm-1"].state, :failed)
      after_failure = Enum.at(tab(state, 170, "Swarm auth"), @dot).style.foreground

      refute before == after_failure
      assert after_failure == Theme.style(:error, state.capabilities).foreground
    end
  end

  describe "how many tabs fit" do
    test "four runs render as four tabs and the fifth becomes +1" do
      state = populated()
      {shown, overflow, _hint} = Shell.tabline_plan(state, 170)

      assert length(shown) == 4
      assert overflow == 1

      row = state |> painted(170) |> hd()

      for {_id, _kind, title, _status, _themed, _role} <- Enum.take(@fleet, 4) do
        assert String.contains?(row, title)
      end

      assert String.contains?(row, "+1")
    end

    test "the overflow counts every run the row left out, not just the fifth" do
      state = populated()
      {shown, overflow, _hint} = Shell.tabline_plan(state, 120)

      assert length(shown) < 4
      assert overflow == 5 - length(shown)
      assert state |> painted(120) |> hd() |> String.contains?("+#{overflow}")
    end

    test "tabs are dropped whole rather than shrunk into stubs" do
      # Every title that is drawn at all is drawn in full, at every width.
      state = populated()

      for width <- [170, 150, 120, 100, 80] do
        {shown, _overflow, _hint} = Shell.tabline_plan(state, width)
        row = state |> painted(width) |> hd()

        for run <- shown do
          assert String.contains?(row, run.title),
                 "#{run.title} was clipped at #{width} columns"
        end
      end
    end

    test "four runs exactly fill the row with no overflow marker" do
      state = populated()
      state = put_in(state.read_model.runs, Map.delete(state.read_model.runs, "chat-1"))

      {shown, overflow, _hint} = Shell.tabline_plan(state, 170)
      assert length(shown) == 4
      assert overflow == 0
      refute state |> painted(170) |> hd() |> String.contains?("+")
    end

    test "superseded runs are neither tabbed nor counted in the overflow" do
      state = populated()
      state = put_in(state.read_model.runs["chat-1"].state, :superseded)

      refute "chat-1" in Enum.map(Shell.tabline_runs(state), & &1.id)

      {shown, overflow, _hint} = Shell.tabline_plan(state, 170)
      assert length(shown) == 4
      assert overflow == 0
    end

    test "an empty read model still produces the row and its hint" do
      state = %{populated() | destination: :activity}
      state = put_in(state.read_model.runs, %{})

      assert {[], 0, @hint} = Shell.tabline_plan(state, 170)
      assert [row] = painted(state, 170)
      assert String.contains?(row, @hint)
    end
  end

  describe "the hint" do
    test "the hint is right-aligned on the same row as the tabs" do
      for width <- [170, 120, 100] do
        assert [row] = populated() |> painted(width)
        assert String.ends_with?(row, @hint), "the hint did not end the row at #{width}"
        assert String.contains?(row, "Release checklist")
      end
    end

    test "a narrow row spends its width on a tab before it spends it on the hint" do
      state = populated()

      # The hint is 42 cells. At the :small and :compressed_small shell widths
      # (50-71 columns) reserving it first leaves 6-27 cells for a tab that costs
      # 24, so the row would announce runs it never shows: a bare "+5" where the
      # one affordance that replaced the navigator should be.
      for width <- [50, 60, 71] do
        {shown, overflow, _hint} = Shell.tabline_plan(state, width)

        assert shown != [], "the tab row drew no tab at all at #{width} columns"
        assert length(shown) + overflow == 5

        assert [row] = painted(state, width)

        assert String.contains?(row, "Release checklist"),
               "the active run was missing from the row at #{width} columns"
      end

      # At the narrowest shell the hint and a tab cannot both be drawn, and it is
      # the hint that goes.
      assert {[_ | _], _overflow, ""} = Shell.tabline_plan(state, 50)
    end

    test "a row too narrow for the hint drops it rather than wrapping" do
      state = populated()
      {_shown, _overflow, hint} = Shell.tabline_plan(state, 40)

      assert hint == ""
      assert [row] = painted(state, 40)
      refute String.contains?(row, "Ctrl-R")
    end
  end

  describe "one painted line" do
    test "the row is exactly one painted line at 170, 120 and 100 columns" do
      state = populated()

      for width <- [170, 120, 100] do
        lines = painted(state, width)

        assert length(lines) == 1,
               "the tab row spanned #{length(lines)} lines at #{width} columns"

        assert Width.cells(hd(lines), :narrow) == width,
               "the tab row did not fill #{width} columns"
      end
    end

    test "the row stays one line under the wide ambiguous-width policy" do
      # Measuring in characters rather than cells would let a tab overflow the
      # row under :wide and wrap it onto a second line.
      state = populated(ambiguous_width: :wide)

      for width <- [170, 120, 100] do
        lines = painted(state, width, policy: :wide)

        assert length(lines) == 1,
               "the tab row spanned #{length(lines)} lines at #{width} columns under :wide"

        assert Width.cells(hd(lines), :wide) == width
      end
    end

    test "the row is one line at every shell width, down to the narrowest" do
      state = populated()

      for width <- [200, 150, 110, 90, 72, 50, 20, 1] do
        assert [_row] = painted(state, width), "the tab row wrapped at #{width} columns"
      end
    end

    test "long titles are elided instead of pushing the row onto a second line" do
      state = populated()
      long = String.duplicate("Release the whole checklist ", 8)
      state = put_in(state.read_model.runs["workflow-1"].title, long)

      assert [row] = painted(state, 170)
      assert Width.cells(row, :narrow) == 170
      assert String.contains?(row, "Release the whole")
      refute String.contains?(row, long)
    end
  end

  describe "ASCII mode" do
    @ascii [
      {"Swarm auth", :kind_swarm_mark},
      {"Review board", :kind_consensus_mark},
      {"Auth landscape", :search_mark},
      {"Release checklist", :glyph_workflows}
    ]

    defp ascii_state, do: populated(ascii?: true)

    test "the marks, the dot and the stripe degrade to their ASCII twins" do
      state = ascii_state()
      row = state |> painted(170, ascii?: true) |> hd()

      for {title, token} <- @ascii do
        unicode = SafeText.value(SafeText.chrome(token))
        twin = SafeText.value(Support.glyph(token, state))

        refute twin == unicode, "#{token} has no distinct ASCII twin"

        assert text(Enum.at(tab(state, 170, title), @mark)) == twin
        refute String.contains?(row, unicode), "#{unicode} survived into ASCII mode"
      end

      dot = SafeText.value(Support.glyph(:dot, state))
      stripe = SafeText.value(Support.glyph(:stripe, state))

      assert dot == SafeText.value(SafeText.chrome(:dot_ascii))
      assert stripe == SafeText.value(SafeText.chrome(:stripe_ascii))
      assert text(Enum.at(tab(state, 170, "Swarm auth"), @dot)) == dot
      assert text(Enum.at(tab(state, 170, "Release checklist"), @stripe)) == stripe

      refute String.contains?(row, SafeText.value(SafeText.chrome(:dot)))
      refute String.contains?(row, SafeText.value(SafeText.chrome(:stripe)))
    end

    test "the ASCII row is still exactly one painted line" do
      state = ascii_state()

      for width <- [170, 120, 100] do
        lines = painted(state, width, ascii?: true)
        assert length(lines) == 1, "the ASCII tab row spanned #{length(lines)} lines at #{width}"
        assert Width.cells(hd(lines), :narrow) == width
      end
    end

    test "ASCII mode keeps the kind and status colours" do
      state = ascii_state()
      tab = tab(state, 170, "Review board")

      {_letter, kind_role} = Theme.run_kind(:consensus_judge)

      assert Enum.at(tab, @mark).style.foreground ==
               Theme.style(kind_role, state.capabilities).foreground

      assert Enum.at(tab, @dot).style.foreground ==
               Theme.style(:error, state.capabilities).foreground
    end
  end
end
