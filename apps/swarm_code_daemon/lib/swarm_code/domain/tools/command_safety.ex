defmodule SwarmCode.Domain.Tools.CommandSafety do
  @moduledoc """
  What a shell command is allowed to cost you (spec 66 T4).

  Before this module `git status` and `rm -rf /` were the same permission class
  (`run_command`'s `permission/1` is `:execute` for everything), so `auto` mode
  asked about both — which is exactly what trains a user to press "Always allow"
  and stop reading. Three classes now:

    * `:safe` — reads something and writes nothing. `auto` and `full_access`
      run it without asking. Never `read_only`: that mode still denies every
      command, safe or not.
    * `:normal` — today's behaviour, an approval in `auto`.
    * `:dangerous` — destroys, publishes or escalates. It asks in **every** mode,
      an "Always allow" of the `:execute` class cannot satisfy it, and its prefix
      is never remembered (T5).

  The classification is the strictest class of any segment of the command, so
  splitting too eagerly can only fail closed. It is a heuristic and it is not a
  sandbox: it decides what to *ask* about, never what the shell may do.
  """

  @type class :: :safe | :normal | :dangerous

  # `||` and `&&` before `|` and `&` — the alternation is tried in order.
  @separators ~r/\|\||&&|;|\||&|\n/

  # spec 67 B3: a substitution is not a separator, so `echo $(rm -rf ~)` used to
  # classify as its argv0 alone — `:safe`, run unasked in `auto`. Two rules now:
  # a segment that contains one is never `:safe`, and every body is classified
  # in its own right (Codex rejects any node outside program/list/pipeline/
  # command/word/string from its safe list, `shell-command/src/bash.rs:29-80`).
  @substitution ~r/\$\(|`|<\(|>\(|\$\{/

  # The innermost substitution bodies of a command: `$(…)`, `` `…` `` and
  # process substitution. Applied round after round, so a nest is unwrapped
  # from the inside out.
  @inner_substitution ~r/\$\(([^()]*)\)|<\(([^()]*)\)|>\(([^()]*)\)|`([^`]*)`/

  # Running a string as a script hides everything it does from every check
  # above. `trap` is handled apart: its action *is* the script.
  @eval ~w(eval source .)

  @trap_action ~r/\btrap\s+(?:'([^']*)'|"([^"]*)"|(\S+))/

  # argv0s that only wrap the real command. `sudo`/`doas` are handled apart:
  # peeling them is itself the finding.
  @wrappers ~w(env nice nohup time timeout xargs stdbuf)
  @shells ~w(sh bash zsh dash ksh)
  @max_depth 8

  # Reads, never writes. Anything with a redirection or a `tee` leaves the list.
  @read_only ~w(ls pwd cat head tail wc file stat du df which type echo printf date uname
                hostname whoami tree basename dirname realpath readlink sort uniq cut tr
                comm diff cmp grep rg ag ack jq yq column less more)

  # spec 73 T18: `stash`, `remote`, `config`, `tag` and `branch` left the
  # list — `git stash` rewrites the working tree, `stash drop` destroys it,
  # `remote set-url` redirects the next push, `config user.email x` writes —
  # and only their read forms are admitted below (`git_safe?/2`).
  @git_read ~w(status diff log show rev-parse describe blame shortlog ls-files)

  # spec 73 T18: the `config` options that read.
  @git_config_reads ~w(--get --get-all --get-regexp --list -l)

  # spec 73 T18: a `branch` option that writes without a positional argument.
  @git_branch_writes ~w(--set-upstream-to --unset-upstream --edit-description
                        -u -m -M -c -C -d -D --delete --move --copy -f --force)

  @destructive ~w(dd diskutil fdisk shutdown reboot halt killall pkill)

  @publish [
    ~w(npm publish),
    ~w(yarn publish),
    ~w(pnpm publish),
    ~w(cargo publish),
    ~w(gem push),
    ~w(twine upload),
    ~w(gh release create),
    ~w(gh pr merge),
    ~w(gh repo delete)
  ]

  # `curl … | sh` has to be seen on the whole command: the pipe is what makes it.
  @curl_pipe ~r/\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|node|ruby|perl)\b/
  @device_write ~r/>\s*\/dev\/(sd|disk|nvme)/

  @doc "How much trust one shell command needs."
  @spec classify(String.t() | nil) :: class()
  def classify(command) when is_binary(command) do
    if Regex.match?(@curl_pipe, command), do: :dangerous, else: classify_at(command, 0)
  end

  def classify(_other), do: :normal

  defp classify_at(_command, depth) when depth > @max_depth, do: :dangerous

  defp classify_at(command, depth) do
    command
    |> segments()
    |> Enum.map(&segment_class(&1, depth))
    |> strictest()
  end

  defp segments(command) do
    command
    |> String.split(@separators)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strictest([]), do: :normal

  defp strictest(classes) do
    cond do
      :dangerous in classes -> :dangerous
      Enum.all?(classes, &(&1 == :safe)) -> :safe
      true -> :normal
    end
  end

  defp segment_class(text, depth) do
    own =
      case peel(String.split(text), depth) do
        :dangerous -> :dangerous
        {:shell, inner} -> classify_at(inner, depth + 1)
        [] -> :normal
        argv -> argv_class(argv, text, depth)
      end

    # A substitution can never leave the segment `:safe` (what it expands to is
    # not knowable here), and whatever it runs counts as part of the command.
    own = if Regex.match?(@substitution, text), do: strictest([own, :normal]), else: own

    strictest([own | Enum.map(substitutions(text, @max_depth), &classify_at(&1, depth + 1))])
  end

  defp substitutions(_text, 0), do: []

  defp substitutions(text, rounds) do
    case Regex.scan(@inner_substitution, text) do
      [] ->
        []

      matches ->
        bodies = Enum.map(matches, fn match -> match |> Enum.drop(1) |> Enum.join() end)
        bodies ++ substitutions(Regex.replace(@inner_substitution, text, " "), rounds - 1)
    end
  end

  # Leading `FOO=1`, then one wrapper, then round again: `env FOO=1 sudo rm` has
  # to reach the `sudo`.
  defp peel(tokens, depth) when depth <= @max_depth do
    tokens = Enum.drop_while(tokens, &assignment?/1)

    case tokens do
      [argv0 | _rest] when argv0 in ~w(sudo doas) ->
        :dangerous

      [argv0 | rest] when argv0 in @wrappers ->
        peel(Enum.drop_while(rest, &wrapper_arg?/1), depth + 1)

      [argv0 | rest] ->
        if base(argv0) in @shells and "-c" in rest,
          do: {:shell, unquote_script(rest)},
          else: [argv0 | rest]

      [] ->
        []
    end
  end

  defp peel(_tokens, _depth), do: :dangerous

  defp assignment?(token), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, token)

  # `timeout 5 rm -rf x`, `nice -n 10 …`: the wrapper's own options and its
  # duration are not the command.
  defp wrapper_arg?(token),
    do: String.starts_with?(token, "-") or Regex.match?(~r/^\d+(\.\d+)?[smhd]?$/, token)

  defp unquote_script(rest) do
    rest
    |> Enum.drop_while(&(&1 != "-c"))
    |> Enum.drop(1)
    |> Enum.join(" ")
    |> String.trim()
    |> String.trim("'")
    |> String.trim("\"")
  end

  defp base(argv0), do: Elixir.Path.basename(argv0)

  defp argv_class([argv0 | rest], text, depth) do
    cond do
      base(argv0) == "trap" -> trap_class(text, depth)
      dangerous?(base(argv0), rest, text) -> :dangerous
      safe?(base(argv0), rest, text) -> :safe
      true -> :normal
    end
  end

  # spec 67 B3: `trap 'rm -rf ~' EXIT` used to be `:normal` — the action is a
  # script the shell runs on the way out, so it is classified as one.
  defp trap_class(text, depth) do
    action =
      case Regex.run(@trap_action, text, capture: :all_but_first) do
        nil -> ""
        groups -> groups |> Enum.reject(&(&1 == "")) |> List.first() |> to_string()
      end

    if action in ["", "-", ":", "true"],
      do: :normal,
      else: strictest([:normal, classify_at(action, depth + 1)])
  end

  # ------------------------------------------------------------------ dangerous

  defp dangerous?(argv0, rest, text) do
    Regex.match?(@device_write, text) or
      argv0 in @eval or
      argv0 in @destructive or
      String.starts_with?(argv0, "mkfs") or
      publish?(argv0, rest) or
      specific_danger(argv0, rest)
  end

  defp publish?(argv0, rest) do
    words = [argv0 | Enum.reject(rest, &String.starts_with?(&1, "-"))]
    Enum.any?(@publish, &(Enum.take(words, length(&1)) == &1))
  end

  defp specific_danger("rm", rest) do
    force? = Enum.any?(rest, &(&1 == "--force" or Regex.match?(~r/^-[A-Za-z]*f/, &1)))

    recursive? =
      Enum.any?(rest, &(&1 == "--recursive" or Regex.match?(~r/^-[A-Za-z]*[rR]/, &1)))

    outside? =
      rest
      |> Enum.reject(&String.starts_with?(&1, "-"))
      |> Enum.any?(
        &(String.starts_with?(&1, "/") or String.starts_with?(&1, "~") or
            String.starts_with?(&1, ".."))
      )

    force? or (recursive? and outside?)
  end

  defp specific_danger("chmod", rest),
    do: Enum.any?(rest, &(&1 in ~w(-R --recursive 777)))

  defp specific_danger("chown", rest), do: Enum.any?(rest, &(&1 in ~w(-R --recursive)))

  defp specific_danger("git", rest), do: git_danger(Enum.reject(rest, &(&1 == "--")))

  defp specific_danger(_argv0, _rest), do: false

  defp git_danger(rest) do
    sub = Enum.find(rest, &(not String.starts_with?(&1, "-")))
    flags = Enum.filter(rest, &String.starts_with?(&1, "-"))
    args = rest |> Enum.reject(&String.starts_with?(&1, "-")) |> Enum.drop(1)

    case sub do
      "push" ->
        Enum.any?(flags, &(&1 in ~w(-f --force --force-with-lease --delete -d))) or
          Enum.any?(args, &String.contains?(&1, ":"))

      "reset" ->
        "--hard" in flags

      "clean" ->
        Enum.any?(flags, &Regex.match?(~r/^-[A-Za-z]*[fxd]/, &1))

      "checkout" ->
        "." in args

      "restore" ->
        "." in args

      "branch" ->
        "-D" in flags or "--delete" in flags

      # spec 73 T18: `drop` and `clear` destroy uncommitted work for good.
      "stash" ->
        List.first(args) in ["drop", "clear"]

      "filter-branch" ->
        true

      "gc" ->
        "--prune=now" in flags

      _other ->
        false
    end
  end

  # ------------------------------------------------------------------ safe

  defp safe?(argv0, rest, text) do
    not redirects?(rest, text) and
      (argv0 in @read_only or find_safe?(argv0, rest) or sed_safe?(argv0, rest) or
         argv0 == "awk" or git_safe?(argv0, rest))
  end

  defp redirects?(rest, text),
    do: String.contains?(text, ">") or String.contains?(text, "|&") or "tee" in rest

  defp find_safe?("find", rest), do: not Enum.any?(rest, &(&1 in ~w(-delete -exec -execdir -ok)))
  defp find_safe?(_argv0, _rest), do: false

  defp sed_safe?("sed", rest),
    do: Enum.any?(rest, &(&1 == "-n")) and not Enum.any?(rest, &String.starts_with?(&1, "-i"))

  defp sed_safe?(_argv0, _rest), do: false

  defp git_safe?("git", rest) do
    rest = Enum.reject(rest, &(&1 == "--"))
    sub = Enum.find(rest, &(not String.starts_with?(&1, "-")))
    flags = Enum.filter(rest, &String.starts_with?(&1, "-"))
    args = rest |> Enum.reject(&String.starts_with?(&1, "-")) |> Enum.drop(1)

    # spec 73 T18: explicit read forms for the subcommands that also write.
    case sub do
      "stash" -> List.first(args) in ["list", "show"]
      "remote" -> args == [] or List.first(args) in ["show", "get-url"]
      "config" -> "--global" not in flags and Enum.any?(flags, &(&1 in @git_config_reads))
      "tag" -> args == [] or "-l" in flags or "--list" in flags
      "branch" -> (args == [] or "-l" in flags or "--list" in flags) and not branch_write?(flags)
      _read -> sub in @git_read
    end
  end

  defp git_safe?(_argv0, _rest), do: false

  defp branch_write?(flags) do
    Enum.any?(flags, fn flag ->
      Enum.any?(@git_branch_writes, &(flag == &1 or String.starts_with?(flag, &1 <> "=")))
    end)
  end

  # ------------------------------------------------------------------ prefix (T5)

  # A driver that does nothing on its own: its whole meaning is in what follows,
  # so a family of just this word would be an approval of the driver (spec 67 B5).
  @drivers ~w(rm mv cp chmod chown kill git npm pnpm yarn docker kubectl gh cargo mix sh bash zsh)

  @doc """
  The command's "family", for the per-project auto-approve list (spec 66 T5):
  the first segment's argv0 plus up to two significant following words.

  `"mix test"` → `"mix test"`, `"git status"` → `"git status"`, `"./bin/x"` →
  `"./bin/x"`. Approving one of these approves that prefix and nothing else.

  spec 67 B4/B5 changed three things, all of them narrowing:

    * a command with more than one segment has **no** family — an approved
      `mix test` covered `mix test && git push origin main`, which is `:normal`
      because it carries no force flag;
    * a flag stays in the family (`rm -r build` → `rm -r`, not `rm`, so
      approving one recursive delete does not approve the next one), and so
      does a word after a subcommand (`git -C vendor status` → `git -C status`);
    * a bare driver (`rm`, `git`, `npm`, `sh`…) and a command carrying a
      substitution get no family at all — `""` means "offer no pill".
  """
  @spec prefix(String.t() | nil) :: String.t()
  def prefix(command) when is_binary(command) do
    case segments(command) do
      [segment] -> single_prefix(segment)
      _none_or_many -> ""
    end
  end

  def prefix(_other), do: ""

  defp single_prefix(segment) do
    with false <- Regex.match?(@substitution, segment),
         [argv0 | rest] <- peel(String.split(segment), 0),
         tokens = family_tokens(argv0, rest),
         false <- tokens == [] and base(argv0) in @drivers do
      Enum.join([argv0 | tokens], " ")
    else
      _other -> ""
    end
  end

  # Up to two words that say what the command *is*:
  #
  #   * a flag **before** any subcommand is part of the identity and is kept —
  #     `rm -r` is not `rm`, `git -C x status` is not `git status`;
  #   * the word straight after such a flag is dropped: it is either the flag's
  #     value (`git -C vendor`) or the operand it applies to (`rm -r build`),
  #     and neither belongs in a family;
  #   * a flag **after** a subcommand only configures a command already named,
  #     and ends the family — `npm test --silent` stays in the `npm test`
  #     family, which is what the user approved;
  #   * anything else — a path, a redirect — ends it too.
  # These take operands, not subcommands: every word after the flags is a file,
  # and a file is never part of a family (`cp -r src dst` is the `cp -r`
  # family, not the `cp -r dst` one).
  @operand_only ~w(rm mv cp chmod chown chgrp ln touch mkdir rmdir kill dd)

  defp family_tokens(argv0, rest) do
    if base(argv0) in @operand_only do
      rest |> Enum.take_while(&flag?/1) |> Enum.take(2)
    else
      subcommand_tokens(rest)
    end
  end

  defp subcommand_tokens(rest) do
    rest
    |> Enum.reduce_while({[], false, false}, fn token, {acc, named?, after_flag} ->
      cond do
        length(acc) >= 2 -> {:halt, {acc, named?, after_flag}}
        flag?(token) and named? -> {:halt, {acc, named?, after_flag}}
        flag?(token) -> {:cont, {acc ++ [token], named?, true}}
        after_flag -> {:cont, {acc, named?, false}}
        plain?(token) -> {:cont, {acc ++ [token], true, false}}
        true -> {:halt, {acc, named?, after_flag}}
      end
    end)
    |> elem(0)
    |> Enum.take(2)
  end

  defp flag?(token), do: String.starts_with?(token, "-") and token not in ["-", "--"]

  defp plain?(token),
    do: token != "" and not String.starts_with?(token, "-") and not String.contains?(token, "/")
end
