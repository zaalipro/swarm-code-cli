defmodule SwarmCode.Domain.ProjectConfig do
  @moduledoc """
  Reads `.swarm_code/config.json` from a project root: hooks, permission
  rules and profiles.

  `effort`, `swarm_effort`, `model` and `swarm_model` are read and shown in
  Settings → Project rules, but not applied: a conversation's own choice and
  your Settings decide (pass 77; changing that precedence is an owner
  decision).
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
          # pass 77 C-FEAT-4: `"workspace-write"` runs model commands under
          # macOS Seatbelt (`SwarmCode.Domain.Tools.Sandbox`); nil is off.
          sandbox: String.t() | nil,
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
          {:ok, map} when is_map(map) ->
            {:ok, parse(strip_denied(map))}

          other ->
            # pass 77 D-FEAT-15: fail-safe as before, but no longer silent.
            line = if match?({:error, %Jason.DecodeError{}}, other), do: error_line(other, data)
            where = if line, do: " (line #{line})", else: ""

            Logger.warning(
              "project config: #{path} is not valid JSON#{where} — its hooks and rules are ignored"
            )

            {:ok, nil}
        end

      {:error, :enoent} ->
        {:ok, nil}

      _ ->
        {:ok, nil}
    end
  end

  @typedoc "What `inspect_file/1` found in a project's config.json."
  @type inspection :: %{
          status: :missing | :ok | :invalid_json | :too_large | :unreadable,
          line: pos_integer() | nil,
          message: String.t() | nil,
          config: t() | nil,
          rule_errors: [String.t()]
        }

  @doc """
  pass 77 D-FEAT-15: `load/1` with the reason. Same bounded read; reports a
  missing, oversized, unreadable or invalid file (with the line of a JSON
  error) and, for a valid one, the parsed config plus every permission rule
  that was dropped. Never raises.
  """
  @spec inspect_file(String.t()) :: inspection()
  def inspect_file(root) when is_binary(root) do
    path = Path.join(root, @config_file)

    case read_bounded(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, map} when is_map(map) ->
            map = strip_denied(map)
            {_rules, dropped} = SwarmCode.Domain.Engine.Rules.parse_report(map["permissions"])

            %{
              status: :ok,
              line: nil,
              message: nil,
              config: parse(map),
              rule_errors: dropped ++ sandbox_errors(map)
            }

          {:ok, _not_an_object} ->
            report(:invalid_json, nil, "the top level must be a JSON object")

          {:error, %Jason.DecodeError{} = error} ->
            line = error_line({:error, error}, data)
            report(:invalid_json, line, error |> Exception.message() |> clip_message())
        end

      {:error, :enoent} ->
        report(:missing, nil, nil)

      {:error, :too_large} ->
        report(:too_large, nil, "is over #{@max_bytes} bytes")

      {:error, reason} ->
        report(:unreadable, nil, "could not be read (#{inspect(reason)})")
    end
  end

  defp report(status, line, message),
    do: %{status: status, line: line, message: message, config: nil, rule_errors: []}

  defp error_line({:error, %Jason.DecodeError{position: pos}}, data) when is_integer(pos) do
    head = binary_part(data, 0, min(pos, byte_size(data)))
    length(:binary.matches(head, "\n")) + 1
  end

  defp error_line(_other, _data), do: nil

  defp clip_message(text) do
    text |> SwarmCode.Domain.LLM.HTTP.redact() |> String.slice(0, 200)
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
      sandbox: parse_sandbox(map["sandbox"]),
      raw: map
    }
  end

  defp parse_sandbox("workspace-write"), do: "workspace-write"
  defp parse_sandbox(_other), do: nil

  # pass 77 D-FEAT-15: a `"sandbox"` value that is not understood is reported
  # beside the dropped rules instead of silently meaning "off".
  defp sandbox_errors(%{"sandbox" => value}) when value != nil do
    if parse_sandbox(value) == nil,
      do: [~s(sandbox: #{inspect(value)} is not supported — the only value is "workspace-write")],
      else: []
  end

  defp sandbox_errors(_map), do: []

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
end
