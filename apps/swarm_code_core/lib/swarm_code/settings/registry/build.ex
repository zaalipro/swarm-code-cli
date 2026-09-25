defmodule SwarmCode.Settings.Registry.Build do
  @moduledoc false
  # Compile-time helpers for the registry entry files (pass 74, spec §3.2).
  # Every function runs while a registry module compiles; nothing here is
  # called with runtime input.

  alias SwarmCode.Settings.Entry

  @effort_format "^[a-z0-9][a-z0-9_-]{0,23}$"

  def effort_format, do: @effort_format

  @doc false
  def entry(key, section, label, opts) do
    scope = Keyword.fetch!(opts, :scope)
    storage = Keyword.fetch!(opts, :storage)
    type = Keyword.fetch!(opts, :type)

    base =
      %Entry{
        key: key,
        id: key |> String.replace(".", "_") |> String.to_atom(),
        section: section,
        label: label,
        scope: scope,
        storage: storage,
        type: type
      }
      |> struct(Keyword.drop(opts, [:scope, :storage, :type]))

    base
    |> put_default(:home, default_home(scope))
    |> put_layers()
    |> put_stored_name()
    |> put_validators()
    |> put_big_step()
    |> put_example()
  end

  def global(key, section, label, opts), do: entry(key, section, label, [scope: :global] ++ opts)

  def session(key, section, label, opts),
    do: entry(key, section, label, [scope: :session] ++ opts)

  def project(key, section, label, opts),
    do: entry(key, section, label, [scope: :project] ++ opts)

  def cli(key, section, label, opts), do: entry(key, section, label, [scope: :cli] ++ opts)

  def fact(key, section, label, source, opts \\ []),
    do: entry(key, section, label, [scope: :fact, storage: {:fact, source}, type: :fact] ++ opts)

  def action(key, section, label, action, opts \\ []),
    do:
      entry(
        key,
        section,
        label,
        [scope: :action, storage: {:action, action}, type: :action, resettable: false] ++ opts
      )

  def link(key, section, label, to_section, to_key, opts \\ []),
    do:
      entry(
        key,
        section,
        label,
        [scope: :link, storage: {:link, to_section, to_key}, type: :link, resettable: false] ++
          opts
      )

  def choices(list) do
    Enum.map(list, fn
      {value, label, hint} -> %{value: value, label: label, hint: hint}
      {value, label} -> %{value: value, label: label, hint: nil}
      value -> %{value: value, label: to_string(value), hint: nil}
    end)
  end

  defp default_home(scope) when scope in [:global, :session, :project, :cli], do: scope
  defp default_home(_scope), do: nil

  defp put_default(entry, field, value) do
    if Map.fetch!(entry, field) == nil, do: Map.put(entry, field, value), else: entry
  end

  defp put_layers(%Entry{layers: [_ | _]} = entry), do: entry

  defp put_layers(%Entry{scope: scope} = entry) do
    layers =
      case scope do
        :global -> [:global, :default]
        :session -> [:session, :default]
        :project -> [:project, :default]
        :cli -> [:cli, :default]
        :project_file -> [:project_file]
        _ -> []
      end

    %{entry | layers: layers}
  end

  defp put_stored_name(%Entry{stored_name: name} = entry) when is_binary(name), do: entry

  defp put_stored_name(%Entry{storage: storage} = entry) do
    name =
      case storage do
        {:setting, field} -> Atom.to_string(field)
        {:setting_pair, provider, model} -> "#{provider} + #{model}"
        {:setting_map, field, key} -> "#{field}[\"#{key}\"]"
        {:conversation, field} -> "conversations.#{field}"
        {:conversation_pair, provider, model} -> "conversations.#{provider} + #{model}"
        :conversation_pinned -> "conversations.pinned_at"
        {:conversation_mode} -> "conversations.mode + consensus + ultra + authoring_workflow"
        {:project, field} -> "projects.#{field}"
        :project_trust -> "projects.trusted_at"
        {:cli, json} -> "cli.json \"#{json}\""
        {:project_file_key, json} when is_binary(json) -> "config.json \"#{json}\""
        _ -> nil
      end

    %{entry | stored_name: name}
  end

  defp put_validators(%Entry{validate: [_ | _]} = entry), do: entry

  defp put_validators(%Entry{type: type, min: min, max: max} = entry)
       when type in [:integer, :duration] and is_integer(min) and is_integer(max) do
    validator =
      if map_size(entry.special) > 0,
        do: {:special_or_range, Map.keys(entry.special), min, max},
        else: {:range, min, max}

    %{entry | validate: [validator]}
  end

  defp put_validators(%Entry{type: :enum} = entry), do: %{entry | validate: [:inclusion]}

  defp put_validators(%Entry{type: :effort} = entry),
    do: %{entry | validate: [{:format, @effort_format}]}

  defp put_validators(%Entry{type: :color} = entry), do: %{entry | validate: [:hex_color]}
  defp put_validators(%Entry{type: :money} = entry), do: %{entry | validate: [:whole_dollars]}
  defp put_validators(entry), do: entry

  defp put_big_step(%Entry{big_step: step} = entry) when is_integer(step), do: entry

  defp put_big_step(%Entry{type: type, min: min, max: max, step: step} = entry)
       when type in [:integer, :duration, :money] do
    too_many? = is_nil(min) or is_nil(max) or (max - min) / step > 50
    if too_many?, do: %{entry | big_step: step * 10}, else: entry
  end

  defp put_big_step(entry), do: entry

  defp put_example(%Entry{example: example} = entry) when not is_nil(example), do: entry

  defp put_example(entry) do
    if Entry.writable?(entry), do: %{entry | example: example_for(entry)}, else: entry
  end

  defp example_for(%Entry{type: :toggle, default: default}), do: not (default == true)

  defp example_for(%Entry{type: :enum, choices: choices, default: default}),
    do: choices |> Enum.map(& &1.value) |> Enum.find(&(&1 != default))

  defp example_for(%Entry{type: :checklist, choices: choices}),
    do: choices |> Enum.map(& &1.value) |> Enum.take(2)

  defp example_for(%Entry{type: type, default: default} = entry)
       when type in [:integer, :duration, :money] do
    candidates = Enum.reject([entry.max, entry.min, 100, 1], &is_nil/1)
    Enum.find(candidates, &(&1 != default)) || 1
  end

  defp example_for(%Entry{type: :text}), do: "Example"
  defp example_for(%Entry{type: :list, item: :domain}), do: ["example.com"]
  defp example_for(%Entry{type: :list, item: :env_name}), do: ["MY_TOKEN_NAME"]
  defp example_for(%Entry{type: :list, item: :command_family}), do: ["mix test"]
  defp example_for(%Entry{type: :list}), do: ["example"]
  defp example_for(%Entry{type: :model}), do: {:model, "DeepSeek", "deepseek-v4-pro"}
  defp example_for(%Entry{type: :effort, default: "high"}), do: "low"
  defp example_for(%Entry{type: :effort}), do: "high"
  defp example_for(%Entry{type: :path}), do: "/bin/sh"
  defp example_for(%Entry{type: :color}), do: "#2DD4BF"
  defp example_for(%Entry{type: :lsp_command}), do: "off"
  defp example_for(%Entry{type: :combo}), do: "ctrl+shift+y"
  defp example_for(%Entry{type: :keys}), do: %{"palette_open" => ["F5"]}
  defp example_for(%Entry{type: :map_readonly}), do: %{"tasks" => true}
  defp example_for(_entry), do: nil
end
