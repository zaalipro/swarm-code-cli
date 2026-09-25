defmodule SwarmCode.Settings.WireBounds do
  @moduledoc """
  One bounds function for both sides of the settings wire (pass 74, spec
  §3.4.1, B3c). `SwarmCode.Protocol.ServiceRequest` calls it when it decodes a
  `settings.query`/`settings.command` (a violation fails decoding) and the
  client's `Request.validate/1` calls it before anything is sent, so an
  oversize edit is refused on its row and never reaches the wire. Nothing is
  truncated: a value outside a bound is an error naming the parameter.
  """

  alias SwarmCode.Settings.Sections

  @views ~w(values overview facts usage open task records record file)

  @actions ~w(values.patch values.reset profile.apply task.cancel export import.preview import.apply
              doctor provider.create provider.update provider.set_key provider.clear_key
              provider.delete provider.test provider.fetch_models provider.apply_models
              provider.fetch_all provider.forget_caps efforts.save efforts.remove_override
              pricing.put_row pricing.delete_row search.update search.set_key search.clear_key
              search.move search.test mcp.create mcp.update mcp.set_secret mcp.toggle
              mcp.set_tools mcp.reconnect mcp.test mcp.delete mcp.import.read mcp.import.apply
              storage.measure storage.plan storage.run storage.vacuum storage.apply_retention
              lsp.check lsp.stop lsp.remove_key file.save file.create file.delete file.clear
              workflow.smoke project_config.put_hook project_config.delete_hook
              project_config.move_hook project_config.put_profile project_config.delete_profile
              project_config.remove_key project_config.remove_entry)

  # The `kind` of a `records` view (collections) and of a `record` view.
  @query_kinds ~w(providers model_options effort_presets pricing_rows unpriced_models
                  search_providers mcp_servers storage_sessions memory_files commands agent_defs
                  skills workflows projects usage_rows provider search_provider mcp_server
                  project_config)

  @query_keys ~w(view sections keys kind id project_id cursor page_size byte_limit options)
  @command_keys ~w(action target attributes expected secrets dry_run)

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "The closed list of settings actions (§3.4.3; the list names 57 actions, its total of 60 is a miscount)."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "The views a `settings.query` may name."
  @spec views() :: [String.t()]
  def views, do: @views

  @doc "The `kind` values of the `records`/`record` views."
  @spec query_kinds() :: [String.t()]
  def query_kinds, do: @query_kinds

  @doc "The exact parameter key set of an operation."
  @spec param_keys(:settings_query | :settings_command) :: [String.t()]
  def param_keys(:settings_query), do: @query_keys
  def param_keys(:settings_command), do: @command_keys

  @doc "Check every parameter of a settings request. `:ok` or the first parameter outside its bound."
  @spec valid?(atom() | String.t(), map()) :: :ok | {:error, String.t()}
  def valid?(op, params) when op in ["settings.query", :settings_query] and is_map(params) do
    first_error([
      {"view", params["view"] in @views},
      {"sections", sections?(params["sections"])},
      {"keys", keys?(params["keys"])},
      {"kind", params["kind"] == nil or params["kind"] in @query_kinds},
      {"id", params["id"] == nil or bounded_text?(params["id"], 1, 512)},
      {"project_id", params["project_id"] == nil or uuid?(params["project_id"])},
      {"cursor", params["cursor"] == nil or bounded_text?(params["cursor"], 1, 256)},
      {"page_size", params["page_size"] == nil or int_in?(params["page_size"], 1, 200)},
      {"byte_limit",
       params["byte_limit"] == nil or int_in?(params["byte_limit"], 4_096, 1_048_576)},
      {"options", options?(params["options"])}
    ])
  end

  def valid?(op, params) when op in ["settings.command", :settings_command] and is_map(params) do
    first_error([
      {"action", params["action"] in @actions},
      {"target", params["target"] == nil or json?(params["target"], 3, 16, 64, 1_024, 1)},
      {"attributes",
       is_map(params["attributes"]) and json?(params["attributes"], 8, 256, 2_048, 262_144, 1)},
      {"expected",
       params["expected"] == nil or
         (is_map(params["expected"]) and json?(params["expected"], 8, 256, 2_048, 262_144, 1))},
      {"secrets", secrets?(params["secrets"])},
      {"dry_run", is_boolean(params["dry_run"])},
      {"attributes", encoded_size_ok?(params)}
    ])
  end

  def valid?(_op, _params), do: {:error, "op"}

  @doc "True when the secrets list has the exact shape (§3.4.1): ≤ 16 `{slot, value}` pairs."
  @spec secrets?(term()) :: boolean()
  def secrets?(secrets) when is_list(secrets) and length(secrets) <= 16 do
    Enum.all?(secrets, fn
      %{"slot" => slot, "value" => value} = secret when map_size(secret) == 2 ->
        bounded_text?(slot, 1, 128) and is_binary(value) and byte_size(value) in 1..8_192 and
          String.valid?(value) and not String.contains?(value, <<0>>)

      _ ->
        false
    end) and Enum.uniq_by(secrets, & &1["slot"]) == secrets
  end

  def secrets?(_secrets), do: false

  defp first_error(checks) do
    case Enum.find(checks, fn {_param, ok?} -> ok? != true end) do
      nil -> :ok
      {param, _} -> {:error, param}
    end
  end

  defp sections?(nil), do: true

  defp sections?(list) when is_list(list) and length(list) <= 32,
    do: Enum.all?(list, &Sections.valid?(to_string_or_nil(&1)))

  defp sections?(_list), do: false

  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(_value), do: nil

  defp keys?(nil), do: true

  defp keys?(list) when is_list(list) and length(list) <= 400,
    do: Enum.all?(list, &bounded_text?(&1, 1, 64))

  defp keys?(_list), do: false

  defp options?(nil), do: true

  defp options?(map) when is_map(map) do
    json?(map, 3, 32, 64, 1_024, 1) and
      (Map.get(map, "slot") == nil or bounded_text?(Map.get(map, "slot"), 1, 32))
  end

  defp options?(_map), do: false

  defp encoded_size_ok?(params) do
    case Jason.encode(params) do
      {:ok, json} -> byte_size(json) <= 900_000
      {:error, _} -> false
    end
  end

  # depth: maximum nesting; entries: map size; items: list length; bytes: string bytes
  defp json?(value, max_depth, entries, items, bytes, depth)
       when is_map(value) and not is_struct(value) do
    depth <= max_depth and map_size(value) <= entries and
      Enum.all?(value, fn {key, item} ->
        bounded_text?(key, 1, 256) and json?(item, max_depth, entries, items, bytes, depth + 1)
      end)
  end

  defp json?(value, max_depth, entries, items, bytes, depth) when is_list(value) do
    depth <= max_depth and length(value) <= items and
      Enum.all?(value, &json?(&1, max_depth, entries, items, bytes, depth + 1))
  end

  defp json?(value, _max_depth, _entries, _items, bytes, _depth) when is_binary(value),
    do: byte_size(value) <= bytes and String.valid?(value)

  defp json?(value, _max_depth, _entries, _items, _bytes, _depth)
       when is_boolean(value) or is_nil(value) or is_number(value),
       do: true

  defp json?(_value, _max_depth, _entries, _items, _bytes, _depth), do: false

  defp bounded_text?(value, min, max) when is_binary(value),
    do:
      byte_size(value) >= min and byte_size(value) <= max and String.valid?(value) and
        control_free?(value)

  defp bounded_text?(_value, _min, _max), do: false

  defp int_in?(value, min, max), do: is_integer(value) and value >= min and value <= max
  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  defp control_free?(<<>>), do: true

  defp control_free?(<<point::utf8, _rest::binary>>)
       when point in 0x00..0x1F or point in 0x7F..0x9F,
       do: false

  defp control_free?(<<_point::utf8, rest::binary>>), do: control_free?(rest)
  defp control_free?(_), do: false
end
