defmodule SwarmCodeCLI.UI.ShellAwarenessTest do
  @moduledoc """
  The shell tells the user what waits on them and what each run costs: the
  status row says "N waiting" and the conversation's cost, the tabs carry
  agent counts, elapsed time and a `!`, the turn's header carries its tokens,
  `n`/`N` walk the pending approvals and questions across runs, and the
  approval card in the composer slot says who wants to run what.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Fixtures,
    Paint,
    Projector,
    Reducer,
    SafeText,
    Size,
    Theme,
    WatchState
  }

  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Keymap.Special
  alias SwarmCodeCLI.UI.Paint.{Blocks, Options, Plan}
  alias SwarmCodeCLI.UI.Projector.{Shell, Status}

  defp fixture(columns \\ 170) do
    size = %Size{columns: columns, rows: 40}
    Fixtures.representative(:chat, size, %Capabilities{size: size, color_mode: :truecolor})
  end

  defp with_workspace(state, fields) do
    run = state.read_model.runs |> Map.values() |> List.first()

    workspace =
      struct(
        %DTO.WorkspaceSnapshot{
          conversation_id: run && run.conversation_id,
          revision: 1,
          runs: Map.values(state.read_model.runs)
        },
        fields
      )

    put_in(state.read_model.snapshots[:workspace], workspace)
  end

  defp approval(id, run_id, opts \\ []) do
    %DTO.PendingInteraction{
      id: id,
      run_id: run_id,
      node_id: Keyword.get(opts, :node_id, "node-" <> id),
      conversation_id: "fixture-conversation",
      kind: :approval,
      expected_revision: 1,
      approval: %DTO.Approval{
        tool: Keyword.get(opts, :tool, "run_command"),
        permission: Keyword.get(opts, :permission, :execute),
        arguments_preview: Keyword.get(opts, :preview, "mix test --failed")
      },
      allowed_actions: [:approve, :deny, :always_allow]
    }
  end

  # One approval on the run in view and two on the next tab. The representative
  # fixture has one run, so a second, older one is added for the walk to cross.
  defp with_waiting(state) do
    [first | _] = Shell.tabline_runs(state)
    second = run("older-run", title: "Older run", created_sequence: -1)
    state = put_in(state.read_model.runs[second.id], second)

    interactions =
      Map.new(
        [approval("a-1", first.id), approval("b-1", second.id), approval("b-2", second.id)],
        &{&1.id, &1}
      )

    state = put_in(state.read_model.interactions, interactions)

    # Navigating between runs opens and closes watches, which the projector
    # fixture does not carry: give it the slots the reducer's init would.
    watches = Map.new([:shell, :workspace, :activity, :inspector], &{&1, %WatchState{}})
    %{state | destination: {:run, first.id}, watches: watches}
  end

  defp screen(state) do
    {scene, _} = Projector.project(state)
    {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor})

    Enum.map_join(0..(state.size.rows - 1), "\n", fn y ->
      Enum.map_join(0..(state.size.columns - 1), "", fn x ->
        case Plan.cell(plan, x, y) do
          {:glyph, g, _, _} -> g
          _ -> " "
        end
      end)
    end)
  end

  defp painted_tabline(state, width) do
    base = %{foreground: nil, background: nil, modifiers: []}
    options = %Options{color_mode: :truecolor, ascii?: false}
    {:ok, lines} = Blocks.lines([Shell.tabline(state, width)], width, options, base, 200, :narrow)
    Enum.map_join(lines, "\n", &Enum.map_join(&1.units, fn unit -> unit.text end))
  end

  defp run(id, opts) do
    %DTO.RunSummary{
      id: id,
      conversation_id: "conversation-#{id}",
      kind: :swarm,
      title: Keyword.get(opts, :title, "Run #{id}"),
      revision: 1,
      state: Keyword.get(opts, :state, :running),
      allowed_actions: [],
      progress: 40,
      created_sequence: Keyword.get(opts, :created_sequence, 0),
      agents_total: Keyword.get(opts, :agents_total, 0),
      needs: Keyword.get(opts, :needs, 0),
      started_at: Keyword.get(opts, :started_at),
      finished_at: Keyword.get(opts, :finished_at)
    }
  end

  defp with_runs(state, runs) do
    state = put_in(state.read_model.runs, Map.new(runs, &{&1.id, &1}))
    %{state | destination: {:run, hd(runs).id}}
  end

  describe "the status row" do
    test "counts what waits on you, in the warning colour, and says nothing at zero" do
      [%{spans: spans}] = Status.project(fixture(), :xl, 170)
      refute Enum.any?(spans, &(SafeText.value(&1.text) =~ "waiting"))

      state = with_waiting(fixture())
      [%{spans: spans}] = Status.project(state, :xl, 170)
      waiting = Enum.find(spans, &(SafeText.value(&1.text) == "3 waiting"))
      assert waiting
      assert waiting.style.foreground == Theme.style(:warning, state.capabilities).foreground
      assert :bold in waiting.style.modifiers
    end

    test "the count survives painting at 80 columns" do
      state = %{with_waiting(fixture(80)) | size: %Size{columns: 80, rows: 24}}
      assert state |> screen() |> String.split("\n") |> List.last() =~ "3 waiting"
    end
  end

  describe "the tab row" do
    setup do
      runs = [
        run("swarm-1",
          title: "Migrate the billing schema to the new ledger",
          agents_total: 3,
          needs: 1,
          started_at: 1_000,
          finished_at: 135_000,
          created_sequence: 2
        ),
        run("swarm-2", title: "Quiet run", created_sequence: 1)
      ]

      %{state: with_runs(fixture(), runs)}
    end

    test "a tab carries its agent count, its duration and a ! for what waits", %{state: state} do
      row = painted_tabline(state, 170)
      assert row =~ "⬢3"
      assert row =~ "02:14"
      assert row =~ "!1"
    end

    test "a run the daemon said nothing about is a bare title", %{state: state} do
      row = painted_tabline(state, 170)
      [_, quiet] = String.split(row, "Quiet run")
      refute quiet =~ "⬢"
      refute quiet =~ "!"
    end

    test "the ! outlives the clock and the agent count as the row narrows", %{state: state} do
      at_100 = painted_tabline(state, 100)
      assert at_100 =~ "⬢3"
      refute at_100 =~ "02:14"
      assert at_100 =~ "!1"

      at_90 = painted_tabline(state, 90)
      refute at_90 =~ "⬢3"
      assert at_90 =~ "!1"
    end

    test "a running run shows its elapsed time only once the clock is set", %{state: state} do
      running = %{state.read_model.runs["swarm-1"] | finished_at: nil}
      state = put_in(state.read_model.runs["swarm-1"], running)

      refute painted_tabline(state, 170) =~ "02:14"
      assert painted_tabline(%{state | now: 135_000}, 170) =~ "02:14"
    end

    test "a long title is cut on a word boundary", %{state: state} do
      row = painted_tabline(state, 170)
      assert row =~ "Migrate the billing…"
      refute row =~ "billing sch"
    end

    test "the row is one painted line at 170, 120 and 100 columns", %{state: state} do
      for width <- [170, 120, 100] do
        refute painted_tabline(state, width) =~ "\n"
      end
    end
  end

  describe "spend" do
    test "the turn's header carries its tokens and the status row the conversation's cost" do
      state = %{fixture() | destination: {:conversation, "fixture-conversation"}}
      rows = String.split(screen(state), "\n")
      assert Enum.any?(rows, &(&1 =~ ~r/\d+k tok/))
      assert List.last(rows) =~ ~r/\$\d+\.\d+/
    end

    test "says nothing about spend until the daemon reports it" do
      state = fixture()

      runs =
        Map.new(state.read_model.runs, fn {id, run} ->
          {id, %{run | tokens_in: 0, tokens_out: 0, cost_usd: nil}}
        end)

      pixels = screen(put_in(state.read_model.runs, runs))
      refute pixels =~ " tok"
      refute pixels =~ "$"
    end
  end

  describe "the title row's lead" do
    test "is the project's name once the daemon says it; the models are on the status row" do
      state =
        with_workspace(fixture(),
          project: "ailogic",
          chat_model: "deepseek-v4.1-flash",
          swarm_model: "gpt-5.5"
        )

      rows = String.split(screen(state), "\n")
      assert String.starts_with?(hd(rows), " ⬢ ailogic   ")
      refute hd(rows) =~ "SAVED"
      assert List.last(rows) =~ "deepseek-v4.1-flash · agents gpt-5.5"
    end

    test "says nothing about the sub agents' model while it is the chat model" do
      state =
        with_workspace(fixture(),
          project: "ailogic",
          chat_model: "deepseek-v4.1-flash",
          swarm_model: "deepseek-v4.1-flash"
        )

      refute state |> screen() |> String.split("\n") |> List.last() =~ "agents "
    end

    test "falls back to the product's name for a saved session without a project" do
      state = with_workspace(%{fixture() | banner: :persisted_banner}, project: nil)
      [title | _] = String.split(screen(state), "\n")
      assert String.starts_with?(title, " ⬢ SwarmCode   ")
      refute title =~ "SAVED"
    end
  end

  describe "the main pane's chrome" do
    test "keeps quiet about a request that went through and says one in flight in words" do
      state = fixture()
      accepted = Map.put(state.mutations, {:composer, "fixture"}, {:settled, "r-1", :accepted})
      refute screen(%{state | mutations: accepted}) =~ "ACCEPTED"

      pending = Map.put(state.mutations, {:composer, "fixture"}, {:pending, "r-2", :noop})
      pixels = screen(%{state | mutations: pending})
      refute pixels =~ "PENDING"
      assert pixels |> String.split("\n") |> List.last() =~ "Sending…"
    end

    test "draws no deck row: the run's actions and the full-text openers are on the keys" do
      state = fixture()

      {id, item} =
        state.read_model.transcript
        |> Enum.filter(fn {_, item} -> item.role == :assistant end)
        |> Enum.max_by(fn {id, _} -> id end)

      item = %{item | detail_ref: %DTO.DetailRef{id: id <> ":text", total_bytes: 9_000}}
      state = put_in(state.read_model.transcript[id], item)

      pixels = screen(state)
      refute pixels =~ "Full reply"
      refute pixels =~ "Inspect"

      {_scene, table} = Projector.project(state)
      assert {:local, {:open_detail, item.run_id, id <> ":text"}} in Map.values(table)
    end
  end

  describe "n and N" do
    test "walk what waits on you across runs, starting from the run in view" do
      state = with_waiting(fixture())
      [first, second | _] = Shell.tabline_runs(state)

      assert {:ok, {:open_interaction, "a-1"}} = Special.run(:next_need, {"n", []}, state, %{})
      {state, _} = Reducer.update(state, {:open_interaction, "a-1"})
      assert [{:approval, "a-1"} | _] = state.layers
      assert state.destination == {:run, first.id}

      assert {:ok, {:open_interaction, "b-1"}} = Special.run(:next_need, {"n", []}, state, %{})
      {state, _} = Reducer.update(state, {:open_interaction, "b-1"})
      assert state.destination == {:run, second.id}
      # The walk replaces the dialog rather than stacking one on another.
      assert [{:approval, "b-1"} | rest] = state.layers
      refute Enum.any?(rest, &match?({:approval, _}, &1))

      assert {:ok, {:open_interaction, "b-2"}} = Special.run(:next_need, {"n", []}, state, %{})

      assert {:ok, {:open_interaction, "a-1"}} =
               Special.run(:previous_need, {"N", []}, state, %{})

      {state, _} = Reducer.update(state, {:open_interaction, "b-2"})
      # Both directions wrap.
      assert {:ok, {:open_interaction, "a-1"}} = Special.run(:next_need, {"n", []}, state, %{})
    end

    test "say so when nothing is waiting" do
      assert {:ok, :nothing_waiting} = Special.run(:next_need, {"n", []}, fixture(), %{})
      assert {:ok, :nothing_waiting} = Special.run(:previous_need, {"N", []}, fixture(), %{})

      {state, effects} = Reducer.update(fixture(), :nothing_waiting)
      assert state.notice == {:command_feedback, "Nothing is waiting on you."}
      assert [{:announce, _}] = effects
    end

    test "an interaction that was resolved meanwhile falls back to the notice" do
      state = with_waiting(fixture())
      {state, _} = Reducer.update(state, {:open_interaction, "missing"})
      assert state.notice == {:command_feedback, "Nothing is waiting on you."}
    end
  end

  describe "the approval card" do
    test "names the agent, shows the command, where it runs and the keys" do
      state = with_waiting(fixture())

      agent = %DTO.AgentSummary{id: "node-a-1", name: "scout-1", role: :sub}
      state = put_in(state.read_model.agents["node-a-1"], agent)
      {state, _} = Reducer.update(state, {:open_interaction, "a-1"})

      {scene, actions} = Projector.project(state)
      assert scene.overlay == nil
      pixels = screen(state)

      # The card sits right above the composer: the title and the command at
      # the bottom of main, the keys on the row above the draft.
      assert pixels =~ "scout-1 wants to run a command"
      assert pixels =~ "$ mix test --failed"
      assert pixels =~ "runs on your machine, in the project"
      assert pixels =~ "y once"
      assert pixels =~ "A for this run"
      assert pixels =~ "d deny"
      assert pixels =~ "Type a message"

      assert Enum.any?(
               Map.values(actions),
               &match?({:intent, {:resolve_approval, _, "node-a-1", "a-1", 1, :approve}}, &1)
             )
    end

    test "falls back to plain words for an unnamed agent and a file change" do
      state = with_waiting(fixture())

      write =
        approval("a-1", elem(state.destination, 1),
          tool: "edit_file",
          permission: :write,
          preview: "lib/app.ex"
        )

      state = put_in(state.read_model.interactions["a-1"], write)
      {state, _} = Reducer.update(state, {:open_interaction, "a-1"})
      pixels = screen(state)

      assert pixels =~ "The assistant wants to change a file"
      assert pixels =~ "lib/app.ex"
      assert pixels =~ "changes files in the project"
    end
  end
end
