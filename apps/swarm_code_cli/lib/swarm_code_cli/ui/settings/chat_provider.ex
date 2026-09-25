defmodule SwarmCodeCLI.UI.Settings.ChatProvider do
  @moduledoc """
  Whether the conversation's chat provider can answer (spec §3.10.1, D11),
  from the workspace metadata's `chat_provider: %{name, usable}` (the
  service projects it after the `--model` overlay). Pure.

  An older service sends the provider's name alone (a string): the client
  cannot tell, so it never refuses on its own and the service decides.
  """

  @providers "F2 opens Settings › Providers"

  @doc """
  `{:missing, name}` (name nil when there is none) while the chat provider
  cannot answer, else nil.
  """
  @spec missing(map()) :: nil | {:missing, String.t() | nil}
  def missing(%{read_model: %{snapshots: snapshots}}) do
    case Map.get(snapshots, :workspace) do
      %{chat_provider: provider} -> from(provider)
      _ -> nil
    end
  end

  def missing(_state), do: nil

  defp from(%{} = provider) do
    usable = field(provider, :usable)
    name = field(provider, :name)

    if usable == false,
      do: {:missing, if(is_binary(name) and String.trim(name) != "", do: name, else: nil)},
      else: nil
  end

  defp from(_provider), do: nil

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @doc "The status words when Enter does not send (§3.10.1)."
  @spec words({:missing, String.t() | nil}) :: String.t()
  def words({:missing, nil}), do: "No model provider is set up yet · " <> @providers

  def words({:missing, name}),
    do: "No model provider can answer: #{name} has no key · " <> @providers

  @doc "The words for the service's own refusal (`provider_required`), the name read from its sentence."
  @spec refusal_words(String.t() | nil) :: String.t()
  def refusal_words(text) when is_binary(text) do
    case Regex.run(~r/^No model provider can answer: (.+?) has no key/u, text) do
      [_, name] -> words({:missing, name})
      _ -> words({:missing, nil})
    end
  end

  def refusal_words(_text), do: words({:missing, nil})

  @doc "The header chip while the chat provider cannot answer."
  @spec chip() :: String.t()
  def chip, do: "no model provider · Providers"

  @doc "Whether a composer text is a message the chat model would answer (not a /command)."
  @spec message?(String.t()) :: boolean()
  def message?(text) when is_binary(text),
    do: not String.starts_with?(String.trim_leading(text), "/")

  def message?(_text), do: false
end
