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
            post_tool_use: [hook()],
            stop: [hook()],
            notification: [hook()],
            user_prompt_submit: [hook()],
            pre_compact: [hook()],
            session_end: [hook()]
          },
          profiles: %{String.t() => map()},
          permissions: SwarmCode.Domain.Engine.Rules.t(),
          raw: map()
        }

  # pass 72 F10: the file is read only up to this size. The contract named an
  # existing bound; there was none (`File.read/1` took any size), so this one
  # is new — a project config over 256 KiB is not a config.
  @max_bytes 262_144

  @spec load(String.t() | nil) :: {:ok, t()} | {:ok, nil}
  def load(nil), do: {:ok, nil}

  def load(root) do
    path = Path.join(root, @config_file)

    case read_bounded(path) do
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

  defp read_bounded(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_bytes ->
        Logger.warning("project config: #{path} is over #{@max_bytes} bytes, ignored")
        {:error, :too_large}

      {:ok, _stat} ->
        File.read(path)

      {:error, reason} ->
        {:error, reason}
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
      # pass 72 F10: `{"allow", "ask", "deny"}` rule lists (`Engine.Rules`).
      permissions: SwarmCode.Domain.Engine.Rules.parse(map["permissions"]),
      raw: map
    }
  end

  defp safe_string(v) when is_binary(v) and v != "", do: v
  defp safe_string(_), do: nil

  # pass 72 F9: five more events (`SwarmCode.Domain.Hooks`). Atoms from a fixed list,
  # never from the file.
  @hook_events ~w(session_start pre_tool_use post_tool_use stop notification
                  user_prompt_submit pre_compact session_end)a

  defp parse_hooks(nil), do: Map.new(@hook_events, &{&1, []})
  defp parse_hooks(map) when not is_map(map), do: parse_hooks(nil)

  defp parse_hooks(map) do
    Map.new(@hook_events, &{&1, parse_hook_list(map[Atom.to_string(&1)])})
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
