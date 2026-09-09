defmodule SwarmCodeCLI.UI.FieldKey do
  @moduledoc "The exact transient field-editor key union."

  alias SwarmCodeCLI.UI.Intent

  @type t ::
          {:layer_query, binary(), :switcher | :jump | :action_menu}
          | {:region_filter, binary()}
          | {:question_other, binary(), non_neg_integer()}
          | {:research_question, binary()}
          | {:feature_field, binary(), binary()}

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_field_key}
  def validate({:layer_query, layer_id, kind} = key)
      when kind in [:switcher, :jump, :action_menu] do
    if Intent.valid_id?(layer_id), do: {:ok, key}, else: {:error, :invalid_field_key}
  end

  def validate({:region_filter, region_id} = key) do
    if Intent.valid_id?(region_id), do: {:ok, key}, else: {:error, :invalid_field_key}
  end

  def validate({:question_other, interaction_id, revision} = key)
      when is_integer(revision) and revision >= 0 do
    if Intent.valid_id?(interaction_id), do: {:ok, key}, else: {:error, :invalid_field_key}
  end

  def validate({:research_question, owner} = key) do
    if Intent.valid_id?(owner), do: {:ok, key}, else: {:error, :invalid_field_key}
  end

  def validate({:feature_field, owner, field} = key) do
    if Intent.valid_id?(owner) and Intent.valid_id?(field),
      do: {:ok, key},
      else: {:error, :invalid_field_key}
  end

  def validate(_key), do: {:error, :invalid_field_key}

  @spec validate!(term()) :: t()
  def validate!(key) do
    case validate(key) do
      {:ok, valid} -> valid
      {:error, :invalid_field_key} -> raise ArgumentError, "invalid field key"
    end
  end
end
