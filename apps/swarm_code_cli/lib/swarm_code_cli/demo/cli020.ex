defmodule SwarmCodeCLI.Demo.Cli020 do
  @moduledoc """
  cli020 E15: gallery scenes for the 0.2.0 features, drawn over the
  `:first_reply` conversation (`Demo.Conversation`). Synthetic data only.

    * `:shell_chip` — a `!mix test --failed` draft: the `$ shell` chip.
    * `:paste_chip` — a draft holding a collapsed paste placeholder.
    * `:image_chip` — a staged image on the composer's rule.
    * `:shell_item` — three `!` commands in the transcript: done, failed, running.
    * `:rewind` — the rewind list; `:rewind_confirm` — its confirm.
    * `:history_search` — Ctrl-R in the composer; `:queue_list` — bare `/queue`.
  """
  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, SafeText, Size, State}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Draft.AttachmentRef
  alias SwarmCodeCLI.Demo.Conversation

  @scenes [
    :shell_chip,
    :paste_chip,
    :image_chip,
    :shell_item,
    :rewind,
    :rewind_confirm,
    :history_search,
    :queue_list
  ]

  @doc "Every scene, in gallery order."
  def scenes, do: @scenes

  @spec state(atom(), Size.t(), Capabilities.t()) :: State.t()
  def state(scene, %Size{} = size, %Capabilities{} = capabilities) when scene in @scenes do
    scene
    |> build(Conversation.state(:first_reply, size, capabilities))
  end

  defp build(:shell_chip, state), do: draft(state, "!mix test --failed")

  defp build(:paste_chip, state),
    do: draft(state, "Why does this fail? [Pasted text #1 · 60 lines] Only the first test.")

  defp build(:image_chip, state) do
    state = draft(state, "What is wrong with this layout?")
    key = State.current_draft_key(state)
    draft = Drafts.fetch(state.drafts, key)

    image =
      AttachmentRef.new!(
        id: "demo-image-1",
        name: elem(SafeText.external("layout.png", SafeText.Limits.content()), 1),
        media_type: "image/png",
        byte_size: 412 * 1024,
        status: :ready,
        reference: "demo-image-ref-1"
      )

    %{state | drafts: Drafts.put(state.drafts, %{draft | attachments: [image]})}
  end

  defp build(:shell_item, state) do
    clock = Conversation.clock()

    items = [
      shell(
        "1",
        "$ git status --short\n M lib/router.ex\n?? test/router_test.exs\n[exit 0]",
        :done,
        0,
        clock - 90_000
      ),
      shell(
        "2",
        "$ mix test test/router_test.exs\n1 test, 1 failure\n[exit 2]",
        :done,
        2,
        clock - 60_000
      ),
      shell("3", "$ mix phx.server", :running, nil, clock - 5_000)
    ]

    model = state.read_model

    model = %{
      model
      | transcript: Map.merge(model.transcript, Map.new(items, &{&1.id, &1})),
        order: Map.update(model.order, :workspace, [], &(&1 ++ Enum.map(items, fn i -> i.id end)))
    }

    %{state | read_model: model}
  end

  defp build(:rewind, state),
    do: layer(state, {:rewind, %{turns: turns(), selected: 1}})

  defp build(:rewind_confirm, state),
    do: layer(state, {:rewind_confirm, Enum.at(turns(), 1)})

  defp build(:history_search, state) do
    clock = Conversation.clock()

    rows = [
      %{
        text: "Run the test suite and fix what fails",
        conversation_id: "c1",
        at: clock - 3_600_000
      },
      %{
        text: "Add a test for the router's error path",
        conversation_id: "c2",
        at: clock - 86_400_000
      },
      %{
        text: "Why does the test helper start the repo twice?",
        conversation_id: "c2",
        at: clock - 3 * 86_400_000
      }
    ]

    layer(state, {:history_search, %{query: "test", rows: rows, selected: 0}})
  end

  defp build(:queue_list, state) do
    workspace =
      state.read_model.snapshots.workspace
      |> Map.merge(%{queued_texts: ["Then run the full suite", "Write the CHANGELOG entry"]})
      |> Map.put(:queued, 2)

    state = put_in(state.read_model.snapshots[:workspace], workspace)
    layer(state, {:queue_list})
  end

  defp turns do
    clock = Conversation.clock()

    [
      %{
        message_id: "m3",
        position: 3,
        turn: 3,
        prompt: "Now add the retry test",
        at: clock - 600_000,
        run_id: "r3",
        files: 2
      },
      %{
        message_id: "m2",
        position: 2,
        turn: 2,
        prompt: "Fix the router's double :browser pipe",
        at: clock - 2 * 3_600_000,
        run_id: "r2",
        files: 1
      },
      %{
        message_id: "m1",
        position: 1,
        turn: 1,
        prompt: "Read the router and list test gaps",
        at: clock - 3 * 3_600_000,
        run_id: "r1",
        files: 0
      }
    ]
  end

  defp shell(n, text, item_state, exit, at) do
    %DTO.TranscriptItem{
      id: "demo-shell-item-" <> n,
      run_id: "demo-shell-" <> n,
      conversation_id: "demo-conversation",
      node_id: "demo-shell-node-" <> n,
      revision: 1,
      role: :assistant,
      state: item_state,
      text: text,
      reasoning: "",
      attempt_id: "demo-shell-attempt-" <> n,
      allowed_actions: [],
      at: at,
      created_sequence: 900 + String.to_integer(n)
    }
    |> Map.put(:kind, :shell)
    |> Map.put(:exit, exit)
  end

  defp layer(state, layer), do: %{state | layers: [layer], focus: "dialog"}

  defp draft(state, text) do
    key = State.current_draft_key(state)
    draft = Drafts.fetch(state.drafts, key)
    {:ok, editor} = Editor.apply(draft.editor, {:paste, text})
    %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
  end
end
