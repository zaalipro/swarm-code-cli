defmodule SwarmCodeCLI.Test.Cli020State do
  @moduledoc false
  # cli020 lane D: a ready conversation whose id is a UUID (lane C's new
  # conversation commands take only UUIDs), keys through `Keymap.resolve/3`
  # and `Reducer.update/2`, and the seam's stub check.

  alias SwarmCodeCLI.UI.{Capabilities, Init, Input, Keymap, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}

  @conversation "0b5e2f8a-3c1d-4e6f-9a7b-1c2d3e4f5a6b"
  def conversation, do: @conversation

  def ready(opts \\ []) do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(
        struct!(
          Init,
          [
            size: size,
            capabilities: %Capabilities{size: size},
            source_epoch: "e",
            destination: {:conversation, @conversation},
            focus: "composer"
          ] ++ Keyword.get(opts, :init, [])
        )
      )

    state
    |> deliver(:shell, %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: "e"}
    })
    |> deliver(
      :workspace,
      struct!(
        %DTO.WorkspaceSnapshot{
          conversation_id: @conversation,
          allowed_actions: [:send, :queue],
          runs: Keyword.get(opts, :runs, []),
          interactions: [],
          transcript: %DTO.TranscriptWindow{items: []},
          runs_page: %DTO.PageInfo{},
          interactions_page: %DTO.PageInfo{}
        },
        Keyword.get(opts, :snapshot, %{})
      )
    )
  end

  defp deliver(state, slot, body) do
    watch = Map.fetch!(state.watches, slot)

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
           body: body
         }}
      )

    state
  end

  def press(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> Reducer.update(state, action)
      :ignore -> {state, []}
    end
  end

  def type(state, text),
    do: elem(Reducer.update(state, {:editor, key(state), {:insert, text}}), 0)

  def paste(state, text),
    do: elem(Reducer.update(state, {:editor, key(state), {:paste, text}}), 0)

  def text(state),
    do: SwarmCodeCLI.UI.Editor.text(SwarmCodeCLI.UI.Drafts.fetch(state.drafts, key(state)).editor)

  def key(state), do: SwarmCodeCLI.UI.State.current_draft_key(state)

  def enter(state), do: press(state, Input.key(:enter))

  def commands(effects), do: for({:command, request} <- effects, do: request.kind)

  @doc "Whether lane C's op `kind` is in this build (the seam sends it)."
  def landed?(kind) do
    match?({:ok, _}, SwarmCodeCLI.UI.Intent.validate(kind))
  end
end
