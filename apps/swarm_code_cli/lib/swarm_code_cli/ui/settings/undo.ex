defmodule SwarmCodeCLI.UI.Settings.Undo do
  @moduledoc """
  The settings history of the session (spec §3.7.10, D38), kept in
  `State.settings_history` so undo and *changed in this session* survive
  closing the layer.

  A step is `%{write_key, label, old, new, inverse, redo, at}`: `inverse` and
  `redo` are the ops (`Settings.Op`) that undo and redo it, each an ordinary
  compare-and-set write. The changelog is what the status row said, newest
  first, with `undo?: false` for what cannot be undone (secrets, deletions,
  cleanups). Secrets never enter a step or an entry: their entries say
  `<Label> replaced · no undo`.

  Bounds: 100 past, 100 future, 200 changelog entries (oldest dropped).
  """

  defstruct past: [], future: [], changelog: []

  @type step :: %{
          write_key: term(),
          label: String.t(),
          old: term(),
          new: term(),
          inverse: term(),
          redo: term(),
          at: integer()
        }
  @type entry :: %{at: integer(), text: String.t(), undo?: boolean(), key: String.t() | nil}
  @type t :: %__MODULE__{past: [step()], future: [step()], changelog: [entry()]}

  @max_past 100
  @max_future 100
  @max_changelog 200

  @doc "The bounds, for tests."
  def bounds, do: %{past: @max_past, future: @max_future, changelog: @max_changelog}

  @doc "A new undoable step; a new change forgets the redo future."
  @spec push(t(), step()) :: t()
  def push(%__MODULE__{} = undo, step) when is_map(step),
    do: %{undo | past: Enum.take([step | undo.past], @max_past), future: []}

  @doc "The newest step to undo, and the history without it (the step moves to the future)."
  @spec pop(t()) :: {step(), t()} | :empty
  def pop(%__MODULE__{past: []}), do: :empty

  def pop(%__MODULE__{past: [step | rest]} = undo),
    do: {step, %{undo | past: rest, future: Enum.take([step | undo.future], @max_future)}}

  @doc "The newest undone step to redo, and the history with it back in the past."
  @spec unpop(t()) :: {step(), t()} | :empty
  def unpop(%__MODULE__{future: []}), do: :empty

  def unpop(%__MODULE__{future: [step | rest]} = undo),
    do: {step, %{undo | future: rest, past: Enum.take([step | undo.past], @max_past)}}

  @doc "Puts a step back where `pop/1` or `unpop/1` took it (the write failed)."
  @spec restore(t(), step(), :undo | :redo) :: t()
  def restore(%__MODULE__{} = undo, step, :undo),
    do: %{
      undo
      | future: List.delete(undo.future, step),
        past: Enum.take([step | undo.past], @max_past)
    }

  def restore(%__MODULE__{} = undo, step, :redo),
    do: %{
      undo
      | past: List.delete(undo.past, step),
        future: Enum.take([step | undo.future], @max_future)
    }

  @doc "Appends a changelog entry (newest first)."
  @spec log(t(), integer(), String.t(), keyword()) :: t()
  def log(%__MODULE__{} = undo, at, text, opts \\ []) when is_binary(text) do
    entry = %{
      at: at,
      text: text,
      undo?: Keyword.get(opts, :undo?, true),
      key: Keyword.get(opts, :key)
    }

    %{undo | changelog: Enum.take([entry | undo.changelog], @max_changelog)}
  end

  @doc "Whether anything can be undone / redone."
  def undo?(%__MODULE__{past: past}), do: past != []
  def redo?(%__MODULE__{future: future}), do: future != []
end
