defmodule SwarmCodeCLI.UI.DataSource.Watch do
  @moduledoc "A bounded, generation-correlated UI watch admission request."

  alias SwarmCodeCLI.UI.Intent
  alias SwarmCodeCLI.UI.RequestResolver.Context

  @enforce_keys [:watch_ref, :slot, :scope, :generation, :page_size, :byte_limit]
  defstruct @enforce_keys

  @type slot :: :shell | :workspace | :activity | :inspector

  @type t :: %__MODULE__{
          watch_ref: binary(),
          slot: slot(),
          scope: SwarmCode.Protocol.Scope.t(),
          generation: non_neg_integer(),
          page_size: 1..200,
          byte_limit: 1..1_048_576
        }

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_watch}
  def validate(
        %__MODULE__{
          watch_ref: watch_ref,
          slot: slot,
          scope: scope,
          generation: generation,
          page_size: page_size,
          byte_limit: byte_limit
        } = watch
      ) do
    valid? =
      map_size(watch) == 7 and Intent.valid_id?(watch_ref) and
        slot in [:shell, :workspace, :activity, :inspector] and Context.valid_scope?(scope) and
        is_integer(generation) and generation >= 0 and generation == scope.generation and
        is_integer(page_size) and page_size in 1..200 and is_integer(byte_limit) and
        byte_limit in 1..1_048_576

    if valid?, do: {:ok, watch}, else: {:error, :invalid_watch}
  end

  def validate(_watch), do: {:error, :invalid_watch}

  @spec validate!(term()) :: t()
  def validate!(watch) do
    case validate(watch) do
      {:ok, valid} -> valid
      {:error, :invalid_watch} -> raise ArgumentError, "invalid data source watch"
    end
  end
end
