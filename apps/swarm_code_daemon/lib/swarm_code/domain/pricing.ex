defmodule SwarmCode.Domain.Pricing do
  @moduledoc """
  Pure cost arithmetic.

  Spec 53b §5: a cached prefix is not billed at the input rate. Prompt caching
  bills three ways — fresh input, a cache *write* at a premium, a cache *read*
  at a fraction — and this app sends a cache breakpoint on every Anthropic
  request, so pricing the whole prompt at the input rate overstates a warm turn
  by up to 10× (Claude Opus 5) or 40× (Claude Fable 5.1).
  """

  # The cache multipliers of the base input rate. A pricing row may name the
  # two rates outright (`"cache_read"` / `"cache_write"`, USD per million
  # tokens); these are what a row that names only `input`/`output` gets.
  #
  # Write is the 5-minute TTL, which is the only `cache_control` this client
  # writes (`{"type": "ephemeral"}` with no `ttl`); the 1-hour TTL is 2× and is
  # reachable only by setting the rate on the row.
  @cache_write_multiplier 1.25
  @cache_read_multiplier 0.1
  # Claude Fable 5.1 / Claude Mythos 5.1 read a cached prefix at $0.25 per MTok
  # against a $10 base — a quarter of Claude Fable 5's rate and half of Claude
  # Opus 5's.
  @fable_51_cache_read_multiplier 0.025

  @doc """
  The cost of `tokens_in` prompt tokens and `tokens_out` output tokens, in USD,
  or nil when the model has no pricing row.
  """
  def cost(pricing, model, tokens_in, tokens_out) do
    cost(pricing, model, tokens_in, tokens_out, %{})
  end

  @doc """
  The same, with the prompt broken down by how it was billed (spec 53b §5).

  `cache` carries `:read` and `:write` token counts, both of which are part of
  `tokens_in` — `tokens_in` is the size of the prompt whatever it was billed as
  (`SwarmCode.Domain.LLM.Result`), so the fresh part is what is left after the two.
  """
  @spec cost(map() | nil, String.t() | nil, non_neg_integer(), non_neg_integer(), map()) ::
          float() | nil
  def cost(pricing, model, tokens_in, tokens_out, cache) do
    case is_map(pricing) && Map.get(pricing, model) do
      %{"input" => input, "output" => output} = row
      when is_number(input) and is_number(output) ->
        read = count(cache[:read])
        write = count(cache[:write])
        fresh = max(tokens_in - read - write, 0)

        Float.round(
          per_million(fresh, input) +
            per_million(read, cache_read_rate(row, model, input)) +
            per_million(write, cache_write_rate(row, input)) +
            per_million(tokens_out, output),
          6
        )

      _ ->
        nil
    end
  end

  @doc "The USD-per-MTok rate a cache read is billed at for `model` (spec 53b §5)."
  @spec cache_read_rate(map(), String.t() | nil, number()) :: number()
  def cache_read_rate(%{"cache_read" => rate}, _model, _input) when is_number(rate), do: rate
  def cache_read_rate(_row, model, input), do: input * cache_read_multiplier(model)

  @doc "The USD-per-MTok rate a 5-minute cache write is billed at (spec 53b §5)."
  @spec cache_write_rate(map(), number()) :: number()
  def cache_write_rate(%{"cache_write" => rate}, _input) when is_number(rate), do: rate
  def cache_write_rate(_row, input), do: input * @cache_write_multiplier

  @doc """
  The fraction of the base input rate a cache read costs: 0.1 everywhere except
  Claude Fable 5.1 / Claude Mythos 5.1, where it is 0.025.
  """
  @spec cache_read_multiplier(String.t() | nil) :: float()
  def cache_read_multiplier(model) when is_binary(model) do
    id = String.downcase(model)

    if String.starts_with?(id, "claude-fable-5-1") or
         String.starts_with?(id, "claude-mythos-5-1"),
       do: @fable_51_cache_read_multiplier,
       else: @cache_read_multiplier
  end

  def cache_read_multiplier(_model), do: @cache_read_multiplier

  defp per_million(tokens, rate), do: tokens / 1_000_000 * rate

  defp count(n) when is_integer(n) and n > 0, do: n
  defp count(_n), do: 0

  def add(nil, nil), do: nil
  def add(a, nil), do: a
  def add(nil, b), do: b
  def add(a, b), do: Float.round(a + b, 6)
end
