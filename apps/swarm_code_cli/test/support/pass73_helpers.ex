defmodule SwarmCodeCLI.UI.Pass73Helpers do
  @moduledoc false
  # Shared by the pass73-K tests: a ready conversation "c", keys through
  # `Keymap.resolve/3` and `Reducer.update/2`, and daemon answers.

  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Init, Input, Keymap, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO, Delivery, Delta}

  @key {"c", :main}
  def key, do: @key

  def run(id, state, opts \\ []) do
    %DTO.RunSummary{
      id: id,
      conversation_id: "c",
      state: state,
      revision: 3,
      kind: Keyword.get(opts, :kind, :chat),
      title: Keyword.get(opts, :title, ""),
      parent_run_id: Keyword.get(opts, :parent, nil),
      started_at: Keyword.get(opts, :started_at, 1),
      allowed_actions: Keyword.get(opts, :actions, [:stop, :pause, :steer])
    }
  end

  def booting(opts \\ []) do
    columns = Keyword.get(opts, :columns, 150)
    size = %Size{columns: columns, rows: Keyword.get(opts, :rows, 40)}

    {state, _} =
      Reducer.init(
        struct!(
          Init,
          [
            size: size,
            capabilities: %Capabilities{size: size},
            source_epoch: "e",
            destination: {:conversation, "c"},
            focus: "composer"
          ] ++ Keyword.get(opts, :init, [])
        )
      )

    state
  end

  def snapshot(runs, extra \\ %{}) do
    struct!(
      %DTO.WorkspaceSnapshot{
        conversation_id: "c",
        allowed_actions: [:send, :queue],
        runs: runs,
        interactions: [],
        transcript: %DTO.TranscriptWindow{items: []},
        runs_page: %DTO.PageInfo{},
        interactions_page: %DTO.PageInfo{}
      },
      extra
    )
  end

  def watch_ready(state, runs \\ [], extra \\ %{}, revision \\ 0) do
    watch = state.watches.workspace

    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :watch_ready,
         watch_ref: watch.watch_ref,
         request_id: nil,
         scope: watch.scope,
         generation: watch.generation,
         revision: revision,
         sequence: nil,
         body: snapshot(runs, extra)
       }}
    )
  end

  def ready(runs \\ [], opts \\ []),
    do:
      opts
      |> booting()
      |> shell_ready()
      |> watch_ready(runs, Keyword.get(opts, :snapshot, %{}))
      |> elem(0)

  # The shell watch carries the project and conversation requests.
  def shell_ready(state) do
    watch = state.watches.shell

    {state, _} =
      Reducer.update(
        state,
        {:data,
         %Delivery{
           kind: :watch_ready,
           watch_ref: watch.watch_ref,
           request_id: nil,
           scope: watch.scope,
           generation: watch.generation,
           revision: 0,
           sequence: nil,
           body: %DTO.ShellSnapshot{
             counts: %DTO.Counts{},
             connection: %DTO.Connection{source_epoch: "e"}
           }
         }}
      )

    state
  end

  def run_update(state, body) do
    watch = state.watches.workspace

    delivery = %Delivery{
      kind: :delta,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 1,
      sequence: watch.sequence + 1,
      body: %Delta{
        kind: :run_update,
        entity_id: body.id,
        run_id: body.id,
        conversation_id: "c",
        body: body,
        revision: 1,
        sequence: watch.sequence + 1
      }
    }

    Reducer.update(state, {:data, delivery})
  end

  def outcome(state, request, status, ids, opts \\ []) do
    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :response,
         request_id: request.request_id,
         watch_ref: nil,
         scope: request.scope,
         generation: request.generation,
         revision: nil,
         sequence: nil,
         body: %DTO.Outcome{
           request_id: request.request_id,
           status: status,
           identifiers: ids,
           feedback: Keyword.get(opts, :feedback),
           error:
             if(status == :accepted,
               do: nil,
               else: Keyword.get(opts, :error, AdmissionError.new(:not_allowed))
             )
         }
       }}
    )
  end

  def press(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> Reducer.update(state, action)
      :ignore -> {state, []}
    end
  end

  def press!(state, input), do: elem(press(state, input), 0)
  def letter(text), do: Input.text_fragment(:press, text, [])
  def ctrl(text), do: Input.text_fragment(:press, text, [:control])
  def text(state), do: Editor.text(Drafts.fetch(state.drafts, @key).editor)

  def type(state, text),
    do: text |> String.graphemes() |> Enum.reduce(state, &press!(&2, letter(&1)))

  def paste(state, text), do: elem(Reducer.update(state, {:editor, @key, {:paste, text}}), 0)

  def requests(effects), do: for({:command, request} <- effects, do: request)

  # Enter with the drawn Send target, the way the session resolves it once
  # the projector has drawn the composer.
  def send(state) do
    {:ok, action} = Keymap.draft_send(state)
    Reducer.update(state, action)
  end
end
