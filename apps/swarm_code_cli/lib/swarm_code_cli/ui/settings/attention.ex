defmodule SwarmCodeCLI.UI.Settings.Attention do
  @moduledoc """
  One *needs attention* item (spec §2.1): a title, the reason in words, a
  severity (`:error` before `:warning`), the section it belongs to and where
  Enter goes (`{:key, registry_key}`, `{:record, kind, id}` or
  `{:section, id}`). The service computes most of them (the `overview` view);
  the client adds AT13 (cli.json) and AT14 (key overrides).
  """

  defstruct id: nil, severity: :warning, section: :overview, target: nil, title: "", reason: ""

  @type t :: %__MODULE__{
          id: String.t(),
          severity: :error | :warning,
          section: atom(),
          target:
            nil | {:key, String.t()} | {:record, String.t(), String.t()} | {:section, atom()},
          title: String.t(),
          reason: String.t()
        }

  @doc "Errors first, then warnings, then in rail order (`order` maps a section to its index)."
  @spec sort([t()], %{atom() => non_neg_integer()}) :: [t()]
  def sort(items, order \\ %{}) do
    Enum.sort_by(items, fn item ->
      {if(item.severity == :error, do: 0, else: 1), Map.get(order, item.section, 99)}
    end)
  end
end
