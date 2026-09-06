defmodule SwarmCode.LLM.EffortsTest do
  @moduledoc "Spec 45 §3: reasoning-effort profiles — defaults, the merge, resolution, presets."
  use ExUnit.Case, async: false

  alias SwarmCode.LLM.{Efforts, OpenAI, Request}
  alias SwarmCode.Providers.Provider

  setup do
    if Process.whereis(SwarmCode.LLM.ProviderCaps) == nil,
      do: start_supervised!(SwarmCode.LLM.ProviderCaps)

    OpenAI.reset_caps()
    :ok
  end

  defp openai(attrs \\ %{}),
    do: struct(%Provider{id: "p-openai", name: "o", kind: "openai"}, attrs)

  defp anthropic(attrs \\ %{}),
    do: struct(%Provider{id: "p-anthropic", name: "a", kind: "anthropic"}, attrs)

  defp request(provider, model, effort, extra \\ []) do
    struct(%Request{provider: provider, model: model, effort: effort}, extra)
  end

  defp wire(provider, model, effort, body \\ %{"max_tokens" => 8192, "temperature" => 0.2}) do
    Efforts.apply(body, request(provider, model, effort))
  end

  # ------------------------------------------------------------- §3.2 defaults

  test "the OpenAI-compatible defaults send reasoning_effort verbatim, max with a bigger budget" do
    assert wire(openai(), "m", "low") == %{
             "max_tokens" => 8192,
             "temperature" => 0.2,
             "reasoning_effort" => "low"
           }

    assert wire(openai(), "m", "high")["reasoning_effort"] == "high"

    max = wire(openai(), "m", "max")
    assert max["reasoning_effort"] == "max"
    assert max["max_tokens"] == 16_384

    # A caller's bigger budget is never cut.
    assert wire(openai(), "m", "max", %{"max_tokens" => 40_000})["max_tokens"] == 40_000
    assert Efforts.keys(openai(), "m") == ["low", "medium", "high", "max"]
  end

  # Spec 53b §2: `display` defaults to "omitted" on Opus 5 / Fable 5.1, the
  # ladder has five rungs, and `max_tokens` caps thinking *plus* the answer.
  test "the Anthropic adaptive defaults send thinking + output_config and drop sampling" do
    body = wire(anthropic(), "claude-opus-5", "high", %{"temperature" => 0.2, "top_p" => 0.9})
    assert body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
    assert body["output_config"] == %{"effort" => "high"}
    assert body["max_tokens"] == 32_000
    refute Map.has_key?(body, "temperature")
    refute Map.has_key?(body, "top_p")

    assert Efforts.keys(anthropic(), "claude-opus-5") ==
             ["low", "medium", "high", "xhigh", "max"]

    assert Efforts.keys(anthropic(), "claude-fable-5-1") ==
             ["low", "medium", "high", "xhigh", "max"]

    # The guide's own starting point for the two deepest levels.
    assert wire(anthropic(), "claude-fable-5-1", "xhigh")["max_tokens"] == 64_000
    assert wire(anthropic(), "claude-opus-5", "max")["max_tokens"] == 64_000

    # A caller's bigger budget is never cut.
    assert wire(anthropic(), "claude-opus-5", "high", %{"max_tokens" => 120_000})["max_tokens"] ==
             120_000

    # The preset the settings editor starts from carries the same body.
    preset = Efforts.preset("anthropic_adaptive")
    assert Enum.map(preset.levels, & &1["key"]) == ["low", "medium", "high", "xhigh", "max"]

    assert Enum.find(preset.levels, &(&1["key"] == "xhigh"))["body"] == %{
             "thinking" => %{"type" => "adaptive", "display" => "summarized"},
             "output_config" => %{"effort" => "xhigh"},
             "max_tokens" => 64_000
           }
  end

  test "the Anthropic legacy defaults send the fixed budget and inflate max_tokens" do
    body = wire(anthropic(), "claude-sonnet-4-5", "high")
    assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 16_000}
    assert body["max_tokens"] == 16_000 + 4096
    refute Map.has_key?(body, "temperature")
    refute Map.has_key?(body, "output_config")

    assert wire(anthropic(), "claude-3-opus", "max")["max_tokens"] == 32_000 + 4096
  end

  test "nil effort, an unknown kind and the fake kind" do
    assert wire(openai(), "m", nil) == %{"max_tokens" => 8192, "temperature" => 0.2}
    assert Efforts.defaults("fake", nil) == Efforts.defaults("openai", nil)
    assert Efforts.levels(nil, nil) == Efforts.defaults("openai", nil)
  end

  # ------------------------------------------------------------- §3.1 merge

  test "merge/2: maps merge recursively, scalars replace, max_tokens takes the max" do
    body = %{
      "max_tokens" => 8192,
      "temperature" => 0.2,
      "google" => %{"thinking_config" => %{"thinking_budget" => 1}, "other" => true}
    }

    level = %{
      "max_tokens" => 4096,
      "temperature" => 1.0,
      "google" => %{"thinking_config" => %{"thinking_level" => "high"}}
    }

    assert Efforts.merge(body, level) == %{
             "max_tokens" => 8192,
             "temperature" => 1.0,
             "google" => %{
               "thinking_config" => %{"thinking_budget" => 1, "thinking_level" => "high"},
               "other" => true
             }
           }

    assert Efforts.merge(%{"max_tokens" => 10}, %{"max_tokens" => 20})["max_tokens"] == 20
    assert Efforts.merge(%{"a" => 1}, nil) == %{"a" => 1}
    # An empty body sends nothing — that is how "off" works.
    assert Efforts.merge(%{"a" => 1}, %{}) == %{"a" => 1}
  end

  # --------------------------------------------------------- §3.3 resolution

  test "a model's own list wins over the provider's, which wins over the defaults" do
    custom = [
      %{"key" => "off", "label" => "Off", "hint" => "", "body" => %{}, "drop" => []},
      %{
        "key" => "xhigh",
        "label" => "XHigh",
        "hint" => "",
        "body" => %{"reasoning_effort" => "xhigh"},
        "drop" => ["temperature"]
      }
    ]

    per_model = [
      %{
        "key" => "deep",
        "label" => "Deep",
        "hint" => "",
        "body" => %{"thinking" => %{"type" => "enabled"}},
        "drop" => []
      }
    ]

    p = openai(%{effort_levels: custom, model_effort_levels: %{"special" => per_model}})

    assert Efforts.keys(p, "m") == ["off", "xhigh"]
    assert Efforts.keys(p, "special") == ["deep"]

    # apply/2 with the model override; an unknown key falls to the list's default.
    assert wire(p, "special", "deep")["thinking"] == %{"type" => "enabled"}
    assert wire(p, "special", "high")["thinking"] == %{"type" => "enabled"}

    body = wire(p, "m", "xhigh")
    assert body["reasoning_effort"] == "xhigh"
    refute Map.has_key?(body, "temperature")

    # "off" merges nothing and drops nothing.
    assert wire(p, "m", "off") == %{"max_tokens" => 8192, "temperature" => 0.2}

    # default_key: medium when present, else the middle level.
    assert Efforts.default_key(openai(), "m") == "medium"
    assert Efforts.default_key(p, "m") == "xhigh"
    assert Efforts.normalise_key("high", p, "m") == "xhigh"
    assert Efforts.normalise_key("off", p, "m") == "off"
    assert Efforts.normalise_key(nil, openai(), "m") == "medium"
  end

  test "a provider that rejected the parameter gets no level at all" do
    p = openai()
    OpenAI.remember_no_effort(p)
    assert Efforts.level(request(p, "m", "high")) == nil
    assert wire(p, "m", "high") == %{"max_tokens" => 8192, "temperature" => 0.2}
  end

  # ------------------------------------------------------------ §3.2 presets

  test "every preset validates and carries an id, a name and kinds" do
    presets = Efforts.presets()
    assert length(presets) == 14
    assert Enum.map(presets, & &1.id) |> Enum.uniq() |> length() == 14

    for preset <- presets do
      assert is_binary(preset.name)
      assert preset.kinds != []
      assert {:ok, levels} = Efforts.validate(preset.levels), "preset #{preset.id}"
      assert levels == preset.levels
    end

    assert Efforts.preset("off").levels == [
             %{
               "key" => "medium",
               "label" => "Medium",
               "hint" => "no effort parameter",
               "body" => %{},
               "drop" => []
             }
           ]

    xhigh = Efforts.preset("openai").levels |> Enum.find(&(&1["key"] == "xhigh"))
    assert xhigh["label"] == "XHigh"

    assert Efforts.preset("dashscope").levels |> hd() |> Map.get("body") == %{
             "enable_thinking" => false
           }
  end

  # ---------------------------------------------------------- §3.2 validate

  test "validate/1 reports a bad key, a duplicate, a non-object body and a bad drop, by index" do
    assert {:error, errors} =
             Efforts.validate([
               %{"key" => "ok", "body" => %{}},
               %{"key" => "Bad Key", "body" => %{}},
               %{"key" => "ok", "body" => %{}},
               %{"key" => "x", "body" => "nope"},
               %{"key" => "y", "body" => %{}, "drop" => "temperature"}
             ])

    assert errors == %{
             1 => "key: lowercase letters, digits, - or _ (24 max)",
             2 => "key: already used",
             3 => "body: must be a JSON object",
             4 => "drop: must be a list of keys"
           }

    # A blank label takes the key's label; drop entries are trimmed.
    assert {:ok, [level]} =
             Efforts.validate([%{"key" => "xhigh", "body" => %{}, "drop" => [" top_p ", ""]}])

    assert level["label"] == "XHigh"
    assert level["drop"] == ["top_p"]
    assert Efforts.validate("nope") == {:error, %{0 => "must be a list of levels"}}
  end

  test "from_rows/1 parses the editor's rows and names the JSON error" do
    rows = [
      %{
        "key" => "high",
        "label" => "",
        "hint" => "",
        "body" => ~s({"reasoning_effort":"high"}),
        "drop" => "temperature, top_p"
      },
      %{
        "key" => "max",
        "label" => "Max",
        "hint" => "",
        "body" => ~s({"reasoning_effort":),
        "drop" => ""
      }
    ]

    assert {:error, %{1 => "body: unexpected token at position " <> _}} = Efforts.from_rows(rows)

    assert {:ok, [level]} = Efforts.from_rows([hd(rows)])
    assert level["body"] == %{"reasoning_effort" => "high"}
    assert level["drop"] == ["temperature", "top_p"]
    assert Efforts.to_rows([level]) |> hd() |> Map.get("drop") == "temperature, top_p"
  end

  # ------------------------------------------------- §2 the columns round-trip
end
