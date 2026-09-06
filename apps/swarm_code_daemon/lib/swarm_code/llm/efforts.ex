defmodule SwarmCode.LLM.Efforts do
  @moduledoc """
  Reasoning-effort profiles (spec 45 §3).

  Efforts are not standardised across APIs: one server wants
  `reasoning_effort: "xhigh"`, another `thinking: {type: enabled}`, a third
  `chat_template_kwargs: {enable_thinking: true}`. A *level* is a small map —
  key, label, hint, a JSON `body` merged into the request at the top level
  (the OpenAI SDK's `extra_body` semantics) and a `drop` list of top-level
  keys removed after the merge (§3.1). A provider carries its own list of
  levels, a model can override the provider's, and without either the
  built-in defaults reproduce the pre-spec-45 wire exactly (§3.2).
  """

  alias SwarmCode.LLM.{Anthropic, ProviderCaps, Request}

  @type level :: %{
          required(String.t()) => String.t() | map() | [String.t()]
        }

  @key_format ~r/^[a-z0-9][a-z0-9_-]{0,23}$/

  @classic_hints %{
    "low" => "fastest",
    "medium" => "balanced",
    "high" => "deeper reasoning",
    "xhigh" => "coding and agentic work",
    "max" => "maximum thinking"
  }

  # Spec 53b §2: `max_tokens` is a hard cap on thinking *plus* the
  # answer on every current Claude model, and thinking is on by default, so the
  # 8 192 struct default truncates mid-answer. `Efforts.merge/2` takes the max
  # of the two, so this is a floor a caller can raise and never a cut.
  # 64 000 at `xhigh`/`max` is the guide's own starting point ("set a large
  # max_tokens … start at 64K"); 128 K is the streamable ceiling and the client
  # always streams.
  @adaptive_max_tokens %{
    "low" => 32_000,
    "medium" => 32_000,
    "high" => 32_000,
    "xhigh" => 64_000,
    "max" => 64_000
  }

  @doc "The `max_tokens` floor an Anthropic adaptive level carries (§2)."
  @spec adaptive_max_tokens(String.t()) :: pos_integer()
  def adaptive_max_tokens(key), do: Map.get(@adaptive_max_tokens, key, 32_000)

  # `display` defaults to "omitted" on Opus 5 and Fable 5.1: the blocks still
  # stream, with an empty `thinking` field, so the reasoning pane this app
  # renders from `thinking_delta` would sit blank for the whole think.
  @adaptive_thinking %{"type" => "adaptive", "display" => "summarized"}

  @doc "The body of one Anthropic adaptive level (§2)."
  @spec adaptive_body(String.t()) :: map()
  def adaptive_body(key) do
    %{
      "thinking" => @adaptive_thinking,
      "output_config" => %{"effort" => key},
      "max_tokens" => adaptive_max_tokens(key)
    }
  end

  @doc "The five effort levels Anthropic's adaptive wire takes, in order (§2)."
  @spec adaptive_keys() :: [String.t()]
  def adaptive_keys, do: ["low", "medium", "high", "xhigh", "max"]

  @doc "The regex a level key (and every effort column) must match."
  def key_format, do: @key_format

  # ------------------------------------------------------------ resolution

  @doc """
  The levels in force for `model` on `provider` (§3.3): the model's own list,
  else the provider's, else the built-in defaults for the provider's kind.
  A nil provider takes the OpenAI-compatible defaults.
  """
  @spec levels(map() | nil, String.t() | nil) :: [level()]
  def levels(nil, _model), do: defaults("openai", nil)

  def levels(provider, model) when is_map(provider) do
    overrides = Map.get(provider, :model_effort_levels) || %{}
    own = Map.get(provider, :effort_levels)

    cond do
      is_binary(model) and is_list(overrides[model]) and overrides[model] != [] ->
        overrides[model]

      is_list(own) and own != [] ->
        own

      true ->
        defaults(Map.get(provider, :kind) || "openai", model)
    end
  end

  @doc "The keys of `levels/2`, in order."
  @spec keys(map() | nil, String.t() | nil) :: [String.t()]
  def keys(provider, model), do: Enum.map(levels(provider, model), & &1["key"])

  @doc "The level called `key`, or nil."
  @spec find(map() | nil, String.t() | nil, String.t() | nil) :: level() | nil
  def find(provider, model, key) when is_binary(key),
    do: Enum.find(levels(provider, model), &(&1["key"] == key))

  def find(_provider, _model, _key), do: nil

  @doc "`\"medium\"` when the list has it, else the middle level's key."
  @spec default_key(map() | nil, String.t() | nil) :: String.t()
  def default_key(provider, model), do: default_key_of(levels(provider, model))

  defp default_key_of([]), do: "medium"

  defp default_key_of(levels) do
    keys = Enum.map(levels, & &1["key"])
    if "medium" in keys, do: "medium", else: Enum.at(keys, div(length(keys), 2))
  end

  @doc """
  A known key stays; anything else (an old value, a key the picked model's
  list lacks, nil) becomes `default_key/2`. Every effort → request site goes
  through here, so a conversation column never carries a key onto the wire
  that the provider's list does not define (§3.3).
  """
  @spec normalise_key(term(), map() | nil, String.t() | nil) :: String.t()
  def normalise_key(value, provider, model) do
    if is_binary(value) and value in keys(provider, model),
      do: value,
      else: default_key(provider, model)
  end

  @doc "The display label of a key: capitalised, `xhigh` → `XHigh`."
  @spec label(String.t() | nil) :: String.t()
  def label("xhigh"), do: "XHigh"
  def label(key) when is_binary(key), do: String.capitalize(key)
  def label(_key), do: "Medium"

  # --------------------------------------------------------------- defaults

  @doc """
  The built-in list per provider kind (§3.2). These reproduce the wire the
  providers sent before profiles existed, with one deliberate change: an
  OpenAI-compatible `max` is sent as `max` (it used to go out as `high`).
  """
  @spec defaults(String.t() | nil, String.t() | nil) :: [level()]
  def defaults("anthropic", model) do
    case Anthropic.thinking_mode(model) do
      :adaptive ->
        for key <- adaptive_keys() do
          key
          |> level(adaptive_body(key))
          |> Map.put("drop", ["temperature", "top_p", "top_k"])
        end

      :legacy ->
        for key <- ["low", "medium", "high", "max"] do
          n = Anthropic.budget(key)

          level(key, %{
            "thinking" => %{"type" => "enabled", "budget_tokens" => n},
            "max_tokens" => n + 4096
          })
          |> Map.put("drop", ["temperature"])
        end
    end
  end

  def defaults(_kind, _model) do
    [
      level("low", %{"reasoning_effort" => "low"}),
      level("medium", %{"reasoning_effort" => "medium"}),
      level("high", %{"reasoning_effort" => "high"}),
      level("max", %{"reasoning_effort" => "max", "max_tokens" => 16_384})
    ]
  end

  defp level(key, body, hint \\ nil) do
    %{
      "key" => key,
      "label" => label(key),
      "hint" => hint || Map.get(@classic_hints, key, ""),
      "body" => body,
      "drop" => []
    }
  end

  # ---------------------------------------------------------------- the wire

  @doc """
  The level `r.effort` resolves to for `r.provider`/`r.model` (§3.4): nil
  without an effort, or once the provider has rejected the parameter this
  session; an unknown key falls back to `default_key/2`.
  """
  @spec level(Request.t()) :: level() | nil
  def level(%Request{effort: nil}), do: nil

  def level(%Request{} = r) do
    if ProviderCaps.effort?(r.provider) do
      find(r.provider, r.model, r.effort) ||
        find(r.provider, r.model, default_key(r.provider, r.model))
    end
  end

  @doc "The level of `r.effort` merged into `body`, its `drop` keys removed (§3.4)."
  @spec apply(map(), Request.t()) :: map()
  def apply(body, %Request{} = r) do
    case level(r) do
      nil -> body
      level -> body |> merge(level["body"]) |> Map.drop(List.wrap(level["drop"]))
    end
  end

  @doc """
  The deep merge of §3.1: maps merge recursively, any other value replaces,
  and a numeric `max_tokens` takes the max of the two — a level can raise the
  answer budget, never cut a caller's bigger one.
  """
  @spec merge(map(), map() | nil) :: map()
  def merge(body, level_body) when is_map(body) and is_map(level_body) do
    Map.merge(body, level_body, fn
      "max_tokens", a, b when is_number(a) and is_number(b) -> max(a, b)
      _key, a, b when is_map(a) and is_map(b) -> merge(a, b)
      _key, _a, b -> b
    end)
  end

  def merge(body, _level_body), do: body

  # ---------------------------------------------------------------- presets

  @doc """
  The presets the settings editor can start from (§3.2): `id`, `name`, the
  provider `kinds` they suit, and their `levels`.
  """
  @spec presets() :: [%{id: String.t(), name: String.t(), kinds: [String.t()], levels: [level()]}]
  def presets do
    openai = ["openai"]
    both = ["openai", "anthropic"]

    [
      preset(
        "openai",
        "OpenAI reasoning_effort",
        openai,
        for(
          k <- ~w(none minimal low medium high xhigh max),
          do: level(k, %{"reasoning_effort" => k})
        )
      ),
      preset(
        "anthropic_adaptive",
        "Anthropic adaptive (Claude 4.6+, 5)",
        ["anthropic"],
        for k <- adaptive_keys() do
          k
          |> level(adaptive_body(k))
          |> Map.put("drop", ["temperature", "top_p", "top_k"])
        end
      ),
      preset(
        "anthropic_budget",
        "Anthropic budget (pre-4.6)",
        ["anthropic"],
        for {k, n} <- [{"low", 1024}, {"medium", 4096}, {"high", 16_000}, {"max", 32_000}] do
          level(k, %{
            "thinking" => %{"type" => "enabled", "budget_tokens" => n},
            "max_tokens" => n + 4096
          })
          |> Map.put("drop", ["temperature"])
        end
      ),
      preset("deepseek", "DeepSeek V4", openai, [
        level("off", %{"thinking" => %{"type" => "disabled"}}, "no thinking"),
        level("high", %{"reasoning_effort" => "high"}),
        level("max", %{"reasoning_effort" => "max"})
      ]),
      preset(
        "dashscope",
        "DashScope / Qwen",
        openai,
        [level("off", %{"enable_thinking" => false}, "no thinking")] ++
          for {k, n} <- [{"low", 1024}, {"medium", 4096}, {"high", 16_384}, {"max", 32_768}] do
            level(k, %{"enable_thinking" => true, "thinking_budget" => n})
          end
      ),
      preset(
        "chat_template",
        "vLLM / SGLang chat_template_kwargs",
        openai,
        [
          level("off", %{"chat_template_kwargs" => %{"enable_thinking" => false}}, "no thinking")
        ] ++
          for k <- ~w(low medium high max) do
            level(k, %{
              "chat_template_kwargs" => %{"enable_thinking" => true},
              "reasoning_effort" => k
            })
          end
      ),
      preset("zai", "Z.ai GLM", openai, [
        level("off", %{"thinking" => %{"type" => "disabled"}}, "no thinking"),
        level("on", %{"thinking" => %{"type" => "enabled"}}, "thinking on"),
        level("high", %{"thinking" => %{"type" => "enabled"}, "reasoning_effort" => "high"}),
        level("max", %{"thinking" => %{"type" => "enabled"}, "reasoning_effort" => "max"})
      ]),
      preset(
        "gemini_level",
        "Gemini thinking_level",
        openai,
        for k <- ~w(low medium high) do
          level(k, %{
            "google" => %{
              "thinking_config" => %{"thinking_level" => k, "include_thoughts" => true}
            }
          })
        end
      ),
      preset(
        "gemini_budget",
        "Gemini thinking_budget",
        openai,
        for {k, n} <- [{"off", 0}, {"low", 1024}, {"medium", 8192}, {"high", 24_576}] do
          level(k, %{"google" => %{"thinking_config" => %{"thinking_budget" => n}}})
        end
      ),
      preset(
        "openrouter",
        "OpenRouter reasoning.effort",
        openai,
        for(
          k <- ~w(none minimal low medium high xhigh max),
          do: level(k, %{"reasoning" => %{"effort" => k}})
        )
      ),
      preset(
        "xai",
        "xAI Grok",
        openai,
        for(k <- ~w(low high xhigh), do: level(k, %{"reasoning_effort" => k}))
      ),
      preset("venice", "Venice", openai, [
        level("off", %{"venice_parameters" => %{"disable_thinking" => true}}, "no thinking"),
        level("on", %{"venice_parameters" => %{"disable_thinking" => false}}, "thinking on")
      ]),
      preset("minimax", "MiniMax adaptive", openai, [
        level("on", %{"thinking" => %{"type" => "adaptive"}}, "adaptive thinking")
      ]),
      preset("off", "Send nothing", both, [level("medium", %{}, "no effort parameter")])
    ]
  end

  defp preset(id, name, kinds, levels), do: %{id: id, name: name, kinds: kinds, levels: levels}

  @doc "The preset with `id`, or nil."
  def preset(id), do: Enum.find(presets(), &(&1.id == id))

  # ------------------------------------------------------------- validation

  @doc """
  Checks a level list: every entry a map with a well-formed, unique `key`, a
  `body` object and a `drop` list of strings. Blank labels take the key's
  label. Errors are keyed by index — `%{2 => "key: already used"}`.
  """
  @spec validate(term()) :: {:ok, [level()]} | {:error, %{non_neg_integer() => String.t()}}
  def validate(list) when is_list(list) do
    {levels, errors, _seen} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, MapSet.new()}, fn {raw, i}, {levels, errors, seen} ->
        case check_level(raw, seen) do
          {:ok, level} -> {[level | levels], errors, MapSet.put(seen, level["key"])}
          {:error, message} -> {levels, Map.put(errors, i, message), seen}
        end
      end)

    if errors == %{}, do: {:ok, Enum.reverse(levels)}, else: {:error, errors}
  end

  def validate(_other), do: {:error, %{0 => "must be a list of levels"}}

  defp check_level(%{} = raw, seen) do
    key = string_of(raw["key"] || raw[:key])
    label = string_of(raw["label"] || raw[:label])
    hint = string_of(raw["hint"] || raw[:hint])
    body = raw["body"] || raw[:body] || %{}
    drop = raw["drop"] || raw[:drop] || []

    cond do
      not Regex.match?(@key_format, key) ->
        {:error, "key: lowercase letters, digits, - or _ (24 max)"}

      MapSet.member?(seen, key) ->
        {:error, "key: already used"}

      not is_map(body) ->
        {:error, "body: must be a JSON object"}

      not (is_list(drop) and Enum.all?(drop, &is_binary/1)) ->
        {:error, "drop: must be a list of keys"}

      true ->
        {:ok,
         %{
           "key" => key,
           "label" => if(label == "", do: label(key), else: label),
           "hint" => hint,
           "body" => body,
           "drop" => Enum.map(drop, &String.trim/1) |> Enum.reject(&(&1 == ""))
         }}
    end
  end

  defp check_level(_raw, _seen), do: {:error, "must be a level"}

  defp string_of(nil), do: ""
  defp string_of(value), do: value |> to_string() |> String.trim()

  # --------------------------------------------------------- the form shape

  @doc """
  The settings editor's rows (§3.5): `body` as one-line JSON, `drop` as a
  comma-separated string.
  """
  @spec to_rows([level()]) :: [map()]
  def to_rows(levels) do
    for l <- levels do
      %{
        "key" => l["key"],
        "label" => l["label"],
        "hint" => l["hint"] || "",
        "body" => Jason.encode!(l["body"] || %{}),
        "drop" => Enum.join(List.wrap(l["drop"]), ", ")
      }
    end
  end

  @doc """
  Rows back into levels: parses the JSON body (`body: unexpected token at
  position 12` on failure) and the drop list, then `validate/1`.
  """
  @spec from_rows([map()]) :: {:ok, [level()]} | {:error, %{non_neg_integer() => String.t()}}
  def from_rows(rows) do
    {parsed, errors} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {row, i}, {parsed, errors} ->
        case parse_body(row["body"]) do
          {:ok, body} ->
            drop =
              row["drop"] |> string_of() |> String.split(",") |> Enum.map(&String.trim/1)

            {[Map.merge(row, %{"body" => body, "drop" => drop}) | parsed], errors}

          {:error, message} ->
            {[Map.put(row, "body", %{}) | parsed], Map.put(errors, i, "body: " <> message)}
        end
      end)

    case validate(Enum.reverse(parsed)) do
      {:ok, levels} when errors == %{} -> {:ok, levels}
      {:ok, _levels} -> {:error, errors}
      {:error, more} -> {:error, Map.merge(more, errors)}
    end
  end

  defp parse_body(nil), do: {:ok, %{}}

  defp parse_body(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:ok, %{}}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = body} ->
            {:ok, body}

          {:ok, _other} ->
            {:error, "must be a JSON object"}

          {:error, %Jason.DecodeError{position: pos}} ->
            {:error, "unexpected token at position #{pos}"}
        end
    end
  end

  defp parse_body(%{} = body), do: {:ok, body}
  defp parse_body(_other), do: {:error, "must be a JSON object"}
end
