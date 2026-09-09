defmodule SwarmCode.Domain.Research.Levels do
  @moduledoc """
  How deep a research goes (spec 24 §1).

  A level is a promise about *depth*, not about load: the step still plans its
  whole fan-out, and `research_max_live` decides how many of those subagents are
  in flight at once.
  """

  # Spec 39 §1.6: one word for a round, everywhere.
  # Spec 47 §1: the key stays `low` — rows, `settings.research_level`, the CSS
  # and forty fixtures are keyed on it — but the word and the shape are new:
  # **Fastest** is one round of four agents that answers in minutes.
  @levels %{
    "low" => %{
      steps: 1,
      fanout: 4,
      label: "Fastest",
      hint: "1 round · 4 agents · minutes, not hours",
      fast?: true
    },
    "medium" => %{
      steps: 2,
      fanout: 3,
      label: "Medium",
      hint: "2 rounds · 3 agents each",
      fast?: false
    },
    "high" => %{
      steps: 3,
      fanout: 4,
      label: "High",
      hint: "3 rounds · 4 agents each",
      fast?: false
    },
    "ultra" => %{
      steps: 4,
      fanout: 10,
      label: "Ultra",
      hint: "4 rounds · 10 agents each",
      fast?: false
    }
  }

  @order ~w(low medium high ultra)
  @default "medium"

  @type t :: %{
          steps: pos_integer(),
          fanout: pos_integer(),
          label: String.t(),
          hint: String.t(),
          fast?: boolean()
        }

  @doc "The four level names, shallowest first."
  @spec names() :: [String.t()]
  def names, do: @order

  @doc "The default level when nothing is chosen."
  @spec default() :: String.t()
  def default, do: @default

  @doc "The level map; an unknown name falls back to medium."
  @spec get(String.t() | atom() | nil) :: t()
  def get(level), do: Map.get(@levels, normalize(level), @levels[@default])

  @doc "True for one of the four names."
  @spec valid?(term()) :: boolean()
  def valid?(level), do: Map.has_key?(@levels, normalize(level))

  @doc """
  `{value, label, hint, agents}` for each level, for the selector. `headlines:
  false` recounts without the per-round headline agent (spec 39 §1.6).
  """
  @spec options(keyword()) :: [{String.t(), String.t(), String.t(), pos_integer()}]
  def options(opts \\ []) do
    for name <- @order do
      %{label: label, hint: hint} = @levels[name]
      {name, label, hint, agents(name, opts)}
    end
  end

  @spec steps(String.t() | nil) :: pos_integer()
  def steps(level), do: get(level).steps

  @spec fanout(String.t() | nil) :: pos_integer()
  def fanout(level), do: get(level).fanout

  @spec label(String.t() | nil) :: String.t()
  def label(level), do: get(level).label

  @spec hint(String.t() | nil) :: String.t()
  def hint(level), do: get(level).hint

  @doc """
  True for a level that runs the fast pipeline (spec 47 §2): no headline agent,
  no LLM pass over the HTML, a per-tier clock in seconds rather than minutes.

  Every branch of the fast pipeline asks this, never `level == "low"`.
  """
  @spec fast?(String.t() | atom() | nil) :: boolean()
  def fast?(level), do: get(level).fast? == true

  @doc """
  Every agent a level starts: a lead and a headline per round, the workers,
  the reporter and the HTML pass. The HTML retry (spec 26 §5.3) is not counted
  — it only runs when the first attempt wrote nothing.

  Spec 47 §1: a fast level starts neither a headline agent nor an HTML one, so
  its count is a lead and its workers per round, plus the one reporter — and it
  does not move when the headline toggle does.

  Spec 48 §2: the designed HTML pass now runs *after* the research, as a run of
  its own, so `design:` takes the `research_auto_design` setting — `"deep"`
  (the default, and the old arithmetic exactly), `"all"`, `"never"`, or a plain
  boolean for a caller that only wants the research's own agents.
  """
  @spec agents(String.t() | nil, keyword()) :: pos_integer()
  def agents(level, opts \\ []) do
    %{steps: steps, fanout: fanout} = get(level)

    if fast?(level) do
      steps * (fanout + 1) + 1 + design(level, opts)
    else
      headline = if Keyword.get(opts, :headlines, true), do: 1, else: 0
      steps * (fanout + 1 + headline) + 1 + design(level, opts)
    end
  end

  defp design(level, opts) do
    case Keyword.get(opts, :design, "deep") do
      mode when mode in ["all", true] -> 1
      mode when mode in ["never", false] -> 0
      _deep -> if fast?(level), do: 0, else: 1
    end
  end

  defp normalize(level) when is_atom(level) and not is_nil(level), do: Atom.to_string(level)
  defp normalize(level) when is_binary(level), do: String.downcase(String.trim(level))
  defp normalize(_level), do: ""
end
