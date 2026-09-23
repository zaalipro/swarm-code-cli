defmodule SwarmCode.Domain.ProjectConfig do
  @moduledoc """
  Reads `.swarm_code/config.json` from a project root and layers it
  under the user's Settings row. Project config provides defaults;
  the Settings row wins on conflict.
  """

  # spec 70 D1

  require Logger

  @config_file ".swarm_code/config.json"

  # Keys a project file must never set — they control where requests go or
  # carry credentials, so a cloned repo must not override them.
  @denylist ~w(
    tavily_api_key
    default_chat_provider_id default_swarm_provider_id
    default_scheduled_provider_id default_workflow_provider_id
    monthly_budget_usd workflow_budget
  )

  @type hook :: %{
          command: String.t(),
          matcher: String.t() | nil,
          timeout_ms: pos_integer(),
          output_cap: pos_integer()
        }

  @type t :: %{
          effort: String.t() | nil,
          swarm_effort: String.t() | nil,
          model: String.t() | nil,
          swarm_model: String.t() | nil,
          hooks: %{
            session_start: [hook()],
            pre_tool_use: [hook()],
            post_tool_use: [hook()]
          },
          profiles: %{String.t() => map()},
          raw: map()
        }

  @spec load(String.t() | nil) :: {:ok, t()} | {:ok, nil}
  def load(nil), do: {:ok, nil}

  def load(root) do
    path = Path.join(root, @config_file)

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, map} when is_map(map) -> {:ok, parse(strip_denied(map))}
          _ -> {:ok, nil}
        end

      {:error, :enoent} ->
        {:ok, nil}

      _ ->
        {:ok, nil}
    end
  end

  @spec merge_defaults(t() | nil, map()) :: map()
  def merge_defaults(nil, settings), do: settings

  def merge_defaults(config, settings) do
    settings
    |> maybe_default(:default_effort, config.effort)
    |> maybe_default(:default_swarm_effort, config.swarm_effort)
  end

  # -- private ---------------------------------------------------------------

  defp strip_denied(map) do
    Enum.reduce(@denylist, map, fn key, acc ->
      if Map.has_key?(acc, key) do
        Logger.warning("project config: denied key #{inspect(key)} stripped")
        Map.delete(acc, key)
      else
        acc
      end
    end)
  end

  defp parse(map) do
    %{
      effort: safe_string(map["effort"]),
      swarm_effort: safe_string(map["swarm_effort"]),
      model: safe_string(map["model"]),
      swarm_model: safe_string(map["swarm_model"]),
      hooks: parse_hooks(map["hooks"]),
      profiles: parse_profiles(map["profiles"]),
      raw: map
    }
  end

  defp safe_string(v) when is_binary(v) and v != "", do: v
  defp safe_string(_), do: nil

  defp parse_hooks(nil), do: %{session_start: [], pre_tool_use: [], post_tool_use: []}
  defp parse_hooks(map) when not is_map(map), do: parse_hooks(nil)

  defp parse_hooks(map) do
    %{
      session_start: parse_hook_list(map["session_start"]),
      pre_tool_use: parse_hook_list(map["pre_tool_use"]),
      post_tool_use: parse_hook_list(map["post_tool_use"])
    }
  end

  defp parse_hook_list(nil), do: []
  defp parse_hook_list(list) when not is_list(list), do: []

  defp parse_hook_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&parse_hook/1)
  end

  defp parse_hook(%{"command" => command} = h) when is_binary(command) and command != "" do
    matcher = validate_matcher(h["matcher"])
    timeout = clamp_int(h["timeout_ms"], 1, 30_000, 10_000)
    cap = clamp_int(h["output_cap"], 1, 16_384, 4_096)

    [%{command: command, matcher: matcher, timeout_ms: timeout, output_cap: cap}]
  end

  defp parse_hook(_), do: []

  defp validate_matcher(nil), do: nil
  defp validate_matcher(s) when not is_binary(s), do: nil

  defp validate_matcher(s) do
    case Regex.compile(s) do
      {:ok, _} ->
        s

      {:error, _} ->
        Logger.warning("project config: invalid hook matcher #{inspect(s)}, ignoring")
        nil
    end
  end

  defp clamp_int(v, min, max, _default) when is_integer(v), do: v |> max(min) |> min(max)
  defp clamp_int(_, _min, _max, default), do: default

  defp parse_profiles(nil), do: %{}
  defp parse_profiles(map) when not is_map(map), do: %{}

  defp parse_profiles(map) do
    map
    |> Enum.filter(fn {k, v} -> valid_profile_name?(k) and is_map(v) end)
    |> Map.new()
  end

  defp valid_profile_name?(name) when is_binary(name) do
    byte_size(name) > 0 and byte_size(name) <= 32 and Regex.match?(~r/\A[\w-]+\z/, name)
  end

  defp valid_profile_name?(_), do: false

  defp maybe_default(settings, _key, nil), do: settings

  defp maybe_default(settings, key, value) do
    case Map.get(settings, key) do
      nil -> Map.put(settings, key, value)
      _ -> settings
    end
  end
end
