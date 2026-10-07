defmodule SwarmCode.Domain.Engine.Rules do
  @moduledoc """
  Pass 72 F10 (CLI 0.2.0, competitors-11): permission rules.

  `.swarm_code/config.json` may carry

      "permissions": {"allow": [...], "ask": [...], "deny": [...]}

  Each rule is `tool` (every call of that tool) or `tool(pattern)`, where the
  pattern is a glob on the call's target: the command of a `run_command`, the
  project-relative path of a file tool (`path`, `from`/`to`, every
  `files[].path`), the URL host of a `web_fetch`. MCP tools go by their full
  name. `*` and `?` are the usual wildcards; in a path `*` stays inside one
  directory and `**` crosses them.

  `decide/4` is pure and fails closed: deny beats ask beats allow; a deny or
  ask on a command matches any segment of a chained command, an allow only a
  single plain command (no `;`, `&`, `|`, redirect, backtick, `$(`, newline);
  on a multi-path tool a deny or ask matches when any path does, an allow only
  when every path does. Rules are read only for a trusted project
  (`for_root/1`, the `SwarmCode.Domain.Hooks` trust gate). A rule is a pattern, not a
  sandbox: what it does not match falls through to the approval mode.
  """

  @type rule :: %{raw: String.t(), tool: String.t(), pattern: String.t() | nil}
  @type t :: %{allow: [rule()], ask: [rule()], deny: [rule()]}
  @type decision :: :allow | :ask | {:deny, String.t()} | :none

  @max_rules 100
  @max_rule_bytes 256
  @rule ~r/\A([A-Za-z0-9_.:*-]+)(?:\((.+)\))?\z/s
  # A command an allow may cover: one plain command, nothing chained,
  # substituted or redirected.
  @compound ~r/[;&|`<>\n\r]|\$\(/
  @segment_split ~r/&&|\|\||[;&|\n\r]/

  @empty %{allow: [], ask: [], deny: []}

  @doc "The rules of a `\"permissions\"` map; anything malformed is dropped."
  @spec parse(term()) :: t()
  def parse(map) when is_map(map) do
    %{
      allow: parse_list(map["allow"]),
      ask: parse_list(map["ask"]),
      deny: parse_list(map["deny"])
    }
  end

  def parse(_other), do: @empty

  defp parse_list(list) when is_list(list) do
    list
    |> Enum.flat_map(&parse_rule/1)
    |> Enum.take(@max_rules)
  end

  defp parse_list(_other), do: []

  defp parse_rule(raw) when is_binary(raw) and byte_size(raw) <= @max_rule_bytes do
    raw = String.trim(raw)

    case Regex.run(@rule, raw) do
      [_, tool] -> [%{raw: raw, tool: tool, pattern: nil}]
      [_, tool, pattern] -> [%{raw: raw, tool: tool, pattern: pattern}]
      _no_match -> []
    end
  end

  defp parse_rule(_other), do: []

  @doc """
  The rules of the project at `root` (or owning the isolation directory
  `root`), or nil: no config, no `"permissions"`, or an untrusted project.
  """
  @spec for_root(String.t() | nil) :: t() | nil
  def for_root(root) when is_binary(root) do
    with true <- SwarmCode.Domain.Hooks.trusted_root?(root),
         %{permissions: %{} = rules} <- SwarmCode.Domain.Hooks.project_config(root),
         false <- rules == @empty do
      rules
    else
      _none -> nil
    end
  end

  def for_root(_root), do: nil

  @doc """
  What the rules say about calling `tool` with `args`. `opts[:root]` is the
  project root the paths are made relative to.
  """
  @spec decide(t() | map() | nil, String.t(), map(), keyword()) :: decision()
  def decide(rules, tool, args, opts \\ [])
  def decide(nil, _tool, _args, _opts), do: :none

  def decide(%{allow: allow, ask: ask, deny: deny}, tool, args, opts) when is_binary(tool) do
    call = target(tool, if(is_map(args), do: args, else: %{}), opts[:root])

    cond do
      rule = Enum.find(deny, &strict_match?(&1, tool, call)) -> {:deny, rule.raw}
      Enum.any?(ask, &strict_match?(&1, tool, call)) -> :ask
      Enum.any?(allow, &allow_match?(&1, tool, call)) -> :allow
      true -> :none
    end
  end

  def decide(%{} = raw, tool, args, opts) when not is_map_key(raw, :allow),
    do: decide(parse(raw), tool, args, opts)

  def decide(_rules, _tool, _args, _opts), do: :none

  # -- targets -----------------------------------------------------------------

  defp target("run_command", %{"command" => command}, _root) when is_binary(command),
    do: {:command, command}

  defp target("web_fetch", %{"url" => url}, _root) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> {:host, String.downcase(host)}
      _other -> :none
    end
  rescue
    _error -> :none
  end

  defp target(_tool, args, root) do
    paths =
      [args["path"], args["from"], args["to"]] ++
        for(%{"path" => p} <- List.wrap(args["files"]), do: p)

    case for(p <- paths, is_binary(p) and p != "", do: relative(p, root)) do
      [] -> :none
      paths -> {:paths, paths}
    end
  end

  defp relative(path, root) when is_binary(root) and root != "" do
    root = Path.expand(root)
    abs = Path.expand(path, root)

    cond do
      abs == root -> "."
      String.starts_with?(abs, root <> "/") -> Path.relative_to(abs, root)
      true -> abs
    end
  end

  defp relative(path, _root), do: String.trim_leading(path, "./")

  # -- matching ----------------------------------------------------------------

  defp tool_match?(%{tool: tool}, name), do: tool == name or glob?(tool, name, :host)

  # deny and ask: any piece of the target is enough.
  defp strict_match?(rule, tool, call) do
    tool_match?(rule, tool) and
      case {rule.pattern, call} do
        {nil, _call} ->
          true

        {_pattern, :none} ->
          false

        {pattern, {:command, command}} ->
          Enum.any?(pieces(command), &glob?(pattern, &1, :command))

        {pattern, {:host, host}} ->
          glob?(pattern, host, :host)

        {pattern, {:paths, paths}} ->
          Enum.any?(paths, &glob?(pattern, &1, :path))
      end
  end

  # allow: the whole target, and only a plain command.
  defp allow_match?(rule, tool, call) do
    tool_match?(rule, tool) and
      case {rule.pattern, call} do
        {nil, _call} ->
          true

        {_pattern, :none} ->
          false

        {pattern, {:command, command}} ->
          plain?(command) and glob?(pattern, String.trim(command), :command)

        {pattern, {:host, host}} ->
          glob?(pattern, host, :host)

        {pattern, {:paths, paths}} ->
          Enum.all?(paths, &glob?(pattern, &1, :path))
      end
  end

  defp plain?(command), do: not Regex.match?(@compound, command)

  defp pieces(command) do
    segments =
      @segment_split
      |> Regex.split(command)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.uniq([String.trim(command) | segments])
  end

  defp glob?(pattern, value, kind) do
    case Regex.compile("\\A" <> glob_source(pattern, kind) <> "\\z", "s") do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _reason} -> false
    end
  end

  defp glob_source(pattern, kind), do: glob_source(pattern, kind, [])

  defp glob_source("", _kind, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp glob_source("**" <> rest, :path, acc), do: glob_source(rest, :path, [".*" | acc])
  defp glob_source("*" <> rest, :path, acc), do: glob_source(rest, :path, ["[^/]*" | acc])
  defp glob_source("?" <> rest, :path, acc), do: glob_source(rest, :path, ["[^/]" | acc])
  defp glob_source("*" <> rest, kind, acc), do: glob_source(rest, kind, [".*" | acc])
  defp glob_source("?" <> rest, kind, acc), do: glob_source(rest, kind, ["." | acc])

  defp glob_source(<<char::utf8, rest::binary>>, kind, acc),
    do: glob_source(rest, kind, [Regex.escape(<<char::utf8>>) | acc])

  defp glob_source(<<byte, rest::binary>>, kind, acc),
    do: glob_source(rest, kind, ["\\x{" <> Integer.to_string(byte, 16) <> "}" | acc])
end
