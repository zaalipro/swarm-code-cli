defmodule SwarmCode.Domain.Tools.CommandSafety do
  @moduledoc """
  What a shell command is allowed to cost you (spec 66 T4).

  Before this module `git status` and `rm -rf /` were the same permission class
  (`run_command`'s `permission/1` is `:execute` for everything), so `auto` mode
  asked about both — which is exactly what trains a user to press "Always allow"
  and stop reading. Three classes now:

    * `:safe` — reads something and writes nothing. `auto` and `full_access`
      run it without asking. Never `read_only`: that mode asks before every
      command, safe or not (pass 72 F1; it used to deny them).
    * `:normal` — today's behaviour, an approval in `auto`.
    * `:dangerous` — destroys, publishes or escalates. It asks in **every** mode,
      an "Always allow" of the `:execute` class cannot satisfy it, and its prefix
      is never remembered (T5).

  The classification is the strictest class of any segment of the command, so
  splitting too eagerly can only fail closed. It is a heuristic and it is not a
  sandbox: it decides what to *ask* about, never what the shell may do.

  spec 74 BUGS-45: segments and words split where the shell splits them —
  never inside quotes, `$(…)` or backticks — and the program is the one the
  shell runs after quoting, grouping and wrappers (`\\rm`, `(rm`, `command
  rm`, `timeout -s KILL 5 rm`, `/usr/bin/sudo`).
  """

  @type class :: :safe | :normal | :dangerous

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

  # argv0s that only wrap the real command, each with the options that take a
  # separate value — `timeout -s KILL 5 rm -f x` has to reach the `rm`, not
  # stop at `KILL` (spec 74 BUGS-45). `command`, `exec` and `builtin` run the
  # command they name, bypassing a function or an alias. `sudo`/`doas`/`su`
  # are handled apart: peeling them is itself the finding.
  @wrappers %{
    "env" => ~w(-u --unset -C --chdir -P -L -U),
    "nice" => ~w(-n --adjustment),
    "nohup" => [],
    "time" => ~w(-f --format -o --output),
    "timeout" => ~w(-s --signal -k --kill-after),
    "xargs" => ~w(-a -d -E -I -J -L -n -P -R -S -s --arg-file --delimiter --eof --replace
         --max-lines --max-args --max-procs --max-chars --process-slot-var),
    "stdbuf" => ~w(-i -o -e --input --output --error),
    "command" => [],
    "exec" => ~w(-a),
    "builtin" => []
  }

  # spec 74 BUGS-45: wrapper options that write a file or move the command
  # elsewhere — `time -o out ls` writes `out`, `env -C / ls` lists `/`.
  @wrapper_unsafe %{"time" => ~w(-o --output -a --append), "env" => ~w(-C --chdir -P)}

  @escalations ~w(sudo doas su)
  @shells ~w(sh bash zsh dash ksh fish csh tcsh)
  @max_depth 8

  # What peeling learned on the way to the real command: `unsafe?` — a wrapper
  # option that writes, or `xargs`, so never `:safe` and never a family;
  # `fed?` — `xargs` appends operands no check here can see; `assignments` —
  # the `NAME=value` words dropped (newest first), which may change what runs.
  @meta %{unsafe?: false, fed?: false, assignments: []}

  # Reads, never writes. Anything with a redirection or a `tee` leaves the list.
  #
  # spec 74 BUGS-2: argv0 alone is not enough — `sort -o`, `rg --pre`,
  # `tree -o`, `yq -i`, `uniq a b` write or execute — so each of these is
  # admitted only when its flags pass `flags_safe?/2` and its file operands
  # stay inside the project (`operands_inside?/2`). `ack` left the list: it
  # reads the project's own `.ackrc`, which a tool write can fill with options.
  @read_only ~w(ls pwd cat head tail wc file stat du df which type echo printf date uname
                hostname whoami tree basename dirname realpath readlink sort uniq cut tr
                comm diff cmp grep rg ag jq yq column less more)

  # spec 74 BUGS-2: these never open what their operands name, so an operand
  # outside the project is only a string (`echo ~`, `basename /a/b`).
  @no_file_operands ~w(pwd echo printf which type date uname hostname whoami basename dirname)

  # spec 74 BUGS-2: the first operand is a pattern or a filter, not a file —
  # unless a flag supplies the pattern (`-e x`, `-f file`).
  @pattern_first ~w(grep rg ag jq yq)
  @pattern_flags ~w(-e --regexp -f --file --from-file)

  # spec 74 BUGS-2: an argv0 with a `/` is a program from the project (a
  # `./ls` a tool just wrote), never the system one — except these directories.
  @system_bins ~w(/bin/ /usr/bin/ /usr/local/bin/ /opt/homebrew/bin/)

  # spec 74 BUGS-2: `sed -n` with nothing but line-address print scripts
  # (`1,20p`, `$p`, `10,$p`). `s///w`, `e`, `r`, `w` and `-i` never match.
  @sed_print ~r/^(\$|\d+)?(,(\$|\d+))?p$/

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
  # spec 74 BUGS-45: and through what runs the interpreter — `| /bin/sh`,
  # `| env bash`, `| sudo -E /usr/bin/env python3`.
  @curl_pipe ~r/\b(curl|wget)\b[^|]*\|\s*(\\?(\S*\/)?(sudo|doas|env|command|exec|nice|nohup)\s+(-\S+\s+|[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*)*["']?\\?(\S*\/)?(sh|bash|zsh|dash|ksh|fish|python[0-9.]*|node|ruby|perl|php)\b/
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

  defp segments(command), do: split_top(command, :segments)

  defp words(segment), do: split_top(segment, :words)

  defp strictest([]), do: :normal

  defp strictest(classes) do
    cond do
      :dangerous in classes -> :dangerous
      Enum.all?(classes, &(&1 == :safe)) -> :safe
      true -> :normal
    end
  end

  defp segment_class(text, depth) do
    {peeled, meta} = peel(words(text), depth, @meta)

    own =
      case peeled do
        :dangerous -> :dangerous
        {:shell, inner} -> classify_at(inner, depth + 1)
        [] -> :normal
        argv -> argv_class(argv, text, depth, meta)
      end

    # spec 74 BUGS-2: `GIT_EXTERNAL_DIFF=sh git diff`, `PATH=.:$PATH ls` — an
    # assignment changes what the command runs, so it can never be `:safe`.
    # spec 74 BUGS-45: nor can a wrapper option that writes (`time -o`) or
    # operands `xargs` reads from stdin, which no check here has seen.
    own =
      if meta.unsafe? or meta.assignments != [],
        do: strictest([own, :normal]),
        else: own

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

  # ------------------------------------------------------------------ lexing

  # spec 74 BUGS-45: split where the shell splits. A separator or a blank
  # inside quotes, `$(…)`, `${…}`, `<(…)`/`>(…)` or backticks is text, so
  # `FOO='a;b' rm -rf ~` is one command and `rm -r "my dir"` has one operand.
  # Words keep their quotes: what they expand to is judged per check. An
  # unclosed quote runs to the end (the shell would refuse the command).
  defp split_top(text, split) do
    text
    |> scan([], [], [], split)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp scan(<<>>, _stack, cur, acc, _split), do: Enum.reverse([piece(cur) | acc])

  defp scan(bin, [], cur, acc, split) do
    case separator(bin, split) do
      {:ok, rest} -> scan(rest, [], [], [piece(cur) | acc], split)
      :none -> step(bin, [], cur, acc, split)
    end
  end

  defp scan(bin, stack, cur, acc, split), do: step(bin, stack, cur, acc, split)

  # `||` before `|` and `&&` before `&`: the old separator regex's order.
  defp separator(<<"||", rest::binary>>, :segments), do: {:ok, rest}
  defp separator(<<"&&", rest::binary>>, :segments), do: {:ok, rest}
  defp separator(<<c, rest::binary>>, :segments) when c in [?;, ?|, ?&, ?\n], do: {:ok, rest}
  defp separator(<<c, rest::binary>>, :words) when c in [?\s, ?\t, ?\n, ?\r], do: {:ok, rest}
  defp separator(_bin, _split), do: :none

  # Single quotes: everything up to the closing quote is text.
  defp step(<<?', rest::binary>>, [:sq | stack], cur, acc, split),
    do: scan(rest, stack, [?' | cur], acc, split)

  defp step(<<c, rest::binary>>, [:sq | _] = stack, cur, acc, split),
    do: scan(rest, stack, [c | cur], acc, split)

  defp step(<<?\\, c, rest::binary>>, stack, cur, acc, split),
    do: scan(rest, stack, [c, ?\\ | cur], acc, split)

  defp step(<<"$(", rest::binary>>, stack, cur, acc, split),
    do: scan(rest, [:paren | stack], [?(, ?$ | cur], acc, split)

  defp step(<<"${", rest::binary>>, stack, cur, acc, split),
    do: scan(rest, [:brace | stack], [?{, ?$ | cur], acc, split)

  defp step(<<?`, rest::binary>>, [:bt | stack], cur, acc, split),
    do: scan(rest, stack, [?` | cur], acc, split)

  defp step(<<?`, rest::binary>>, stack, cur, acc, split),
    do: scan(rest, [:bt | stack], [?` | cur], acc, split)

  defp step(<<?", rest::binary>>, [:dq | stack], cur, acc, split),
    do: scan(rest, stack, [?" | cur], acc, split)

  # Double quotes: only `$(`, `${`, backticks and backslashes mean anything.
  defp step(<<c, rest::binary>>, [:dq | _] = stack, cur, acc, split),
    do: scan(rest, stack, [c | cur], acc, split)

  defp step(<<?", rest::binary>>, stack, cur, acc, split),
    do: scan(rest, [:dq | stack], [?" | cur], acc, split)

  defp step(<<?', rest::binary>>, stack, cur, acc, split),
    do: scan(rest, [:sq | stack], [?' | cur], acc, split)

  defp step(<<c, ?(, rest::binary>>, stack, cur, acc, split) when c in [?<, ?>],
    do: scan(rest, [:paren | stack], [?(, c | cur], acc, split)

  defp step(<<?(, rest::binary>>, [:paren | _] = stack, cur, acc, split),
    do: scan(rest, [:paren | stack], [?( | cur], acc, split)

  defp step(<<?), rest::binary>>, [:paren | stack], cur, acc, split),
    do: scan(rest, stack, [?) | cur], acc, split)

  defp step(<<?}, rest::binary>>, [:brace | stack], cur, acc, split),
    do: scan(rest, stack, [?} | cur], acc, split)

  defp step(<<c, rest::binary>>, stack, cur, acc, split),
    do: scan(rest, stack, [c | cur], acc, split)

  defp piece(cur), do: cur |> Enum.reverse() |> IO.iodata_to_binary()

  # spec 74 BUGS-45: a word as the program receives it — quotes removed, a
  # backslash keeps the character after it. `$…` stays as written: whether it
  # expands is exactly what the checks look for.
  defp unquote_word(word), do: unquote_word(word, nil, [])

  defp unquote_word(<<>>, _quote, acc), do: piece(acc)
  defp unquote_word(<<?', rest::binary>>, :sq, acc), do: unquote_word(rest, nil, acc)
  defp unquote_word(<<c, rest::binary>>, :sq, acc), do: unquote_word(rest, :sq, [c | acc])
  defp unquote_word(<<?", rest::binary>>, :dq, acc), do: unquote_word(rest, nil, acc)

  defp unquote_word(<<?\\, c, rest::binary>>, :dq, acc) when c in [?", ?\\, ?$, ?`],
    do: unquote_word(rest, :dq, [c | acc])

  defp unquote_word(<<c, rest::binary>>, :dq, acc), do: unquote_word(rest, :dq, [c | acc])
  defp unquote_word(<<?\\, c, rest::binary>>, nil, acc), do: unquote_word(rest, nil, [c | acc])
  defp unquote_word(<<?', rest::binary>>, nil, acc), do: unquote_word(rest, :sq, acc)
  defp unquote_word(<<?", rest::binary>>, nil, acc), do: unquote_word(rest, :dq, acc)
  defp unquote_word(<<c, rest::binary>>, nil, acc), do: unquote_word(rest, nil, [c | acc])

  # ------------------------------------------------------------------ peeling

  # Leading `FOO=1`, then one wrapper, then round again: `env FOO=1 sudo rm` has
  # to reach the `sudo`.
  defp peel(words, depth, meta) when depth <= @max_depth do
    case lead(words, meta) do
      {[], meta} ->
        {[], meta}

      {[argv0 | rest], meta} ->
        name = base(argv0)

        cond do
          name in @escalations ->
            {:dangerous, meta}

          name == "env" and split_string(rest) != nil ->
            {{:shell, split_string(rest)}, meta}

          Map.has_key?(@wrappers, name) ->
            {rest, meta} = wrapper_rest(name, rest, meta)
            peel(rest, depth + 1, meta)

          name in @shells and shell_script(rest) != nil ->
            {{:shell, shell_script(rest)}, meta}

          true ->
            {[argv0 | rest], meta}
        end
    end
  end

  defp peel(_words, _depth, meta), do: {:dangerous, meta}

  # spec 74 BUGS-45: the words in front of the program that the shell eats —
  # `NAME=value`, a subshell's `(`, a group's `{`, a pipeline's `!` — and the
  # program's name as the shell resolves it: `\rm`, `"rm"`, `'r'm` and `(rm`
  # are all `rm`.
  defp lead([word | rest], meta) do
    name = word |> unquote_word() |> String.replace(~r/^[({]+|[)}]+$/, "")

    cond do
      name in ["", "!"] ->
        lead(rest, meta)

      assignment?(name) ->
        lead(rest, %{meta | assignments: [word | meta.assignments]})

      true ->
        {[name | rest], meta}
    end
  end

  defp lead([], meta), do: {[], meta}

  defp assignment?(token), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, token)

  # The wrapper's own options — with their values — and `timeout`'s duration
  # are not the command.
  defp wrapper_rest(name, rest, meta) do
    unsafe = Map.get(@wrapper_unsafe, name, [])
    {rest, meta} = drop_options(rest, Map.fetch!(@wrappers, name), unsafe, meta)
    meta = if name == "xargs", do: %{meta | fed?: true, unsafe?: true}, else: meta
    {if(name == "timeout", do: drop_duration(rest), else: rest), meta}
  end

  defp drop_options([word | rest], values, unsafe, meta) do
    flag = unquote_word(word)
    meta = if long?(flag, unsafe), do: %{meta | unsafe?: true}, else: meta

    cond do
      flag == "--" -> {rest, meta}
      flag in values -> drop_options(Enum.drop(rest, 1), values, unsafe, meta)
      String.starts_with?(flag, "-") -> drop_options(rest, values, unsafe, meta)
      true -> {[word | rest], meta}
    end
  end

  defp drop_options([], _values, _unsafe, meta), do: {[], meta}

  defp drop_duration([word | rest] = words) do
    if Regex.match?(~r/^\d+(\.\d+)?[smhd]?$/, unquote_word(word)), do: rest, else: words
  end

  defp drop_duration([]), do: []

  # `env -S 'rm -rf ~'` splits its argument into a command line. Only env's
  # own options count: in `env rm -S x` the `-S` belongs to `rm`.
  defp split_string(rest), do: rest |> Enum.map(&unquote_word/1) |> env_split()

  defp env_split(["--split-string=" <> script | after_flag]),
    do: Enum.join([script | after_flag], " ")

  defp env_split(["--split-string" | after_flag]), do: Enum.join(after_flag, " ")

  defp env_split([flag | after_flag]) do
    values = Map.fetch!(@wrappers, "env")

    cond do
      match = Regex.run(~r/^-[A-Za-z0-9]*S(.*)$/s, flag) ->
        Enum.join(Enum.reject([List.last(match) | after_flag], &(&1 == "")), " ")

      flag in values ->
        env_split(Enum.drop(after_flag, 1))

      String.starts_with?(flag, "-") and flag != "--" ->
        env_split(after_flag)

      true ->
        nil
    end
  end

  defp env_split([]), do: nil

  # `sh -c 'script'`, and the bundles `bash -lc`, `sh -ec`, `zsh -xc`: the
  # script, and every word after it (joined, so a split script fails closed).
  # Only the shell's own options count — in `bash x.sh -c ls` the `-c` is an
  # argument of `x.sh`, and `x.sh` is what runs.
  defp shell_script(rest), do: rest |> Enum.map(&unquote_word/1) |> shell_c()

  defp shell_c([word | rest]) do
    cond do
      Regex.match?(~r/^-[A-Za-z]*c[A-Za-z]*$/, word) -> rest |> Enum.join(" ") |> String.trim()
      word in ~w(-o +o -O +O --rcfile --init-file) -> shell_c(Enum.drop(rest, 1))
      String.starts_with?(word, ["-", "+"]) and word != "--" -> shell_c(rest)
      true -> nil
    end
  end

  defp shell_c([]), do: nil

  defp base(argv0), do: Elixir.Path.basename(argv0)

  # `rest` keeps its quotes for the `:safe` checks, which read them; the
  # `:dangerous` checks see the words as the program receives them, so
  # `rm "-rf" ~` and `git push "+main"` are what they look like to rm and git.
  defp argv_class([argv0 | rest], text, depth, meta) do
    name = base(argv0)
    words = Enum.map(rest, &unquote_word/1)

    cond do
      name == "trap" -> trap_class(text, depth)
      dangerous?(name, words, text, meta) -> :dangerous
      name == "git" and git_config_danger?(words, depth) -> :dangerous
      name == "find" and find_bodies(words) != [] -> find_class(words, depth)
      system_argv0?(argv0) and safe?(name, rest, text) -> :safe
      true -> :normal
    end
  end

  defp system_argv0?(argv0) do
    not String.contains?(argv0, "/") or
      Enum.any?(@system_bins, fn dir ->
        String.starts_with?(argv0, dir) and
          not String.contains?(String.replace_prefix(argv0, dir, ""), "/")
      end)
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

  defp dangerous?(argv0, rest, text, meta) do
    Regex.match?(@device_write, text) or
      argv0 in @eval or
      argv0 in @destructive or
      String.starts_with?(argv0, "mkfs") or
      publish?(argv0, rest) or
      specific_danger(argv0, rest, meta)
  end

  defp publish?(argv0, rest) do
    words = [argv0 | Enum.reject(rest, &String.starts_with?(&1, "-"))]
    Enum.any?(@publish, &(Enum.take(words, length(&1)) == &1))
  end

  # spec 74 BUGS-45: a recursive delete is dangerous when an operand is not a
  # plain path inside the project — `rm -r $HOME`, `rm -r "/Users/x"`, a glob
  # — or when `xargs` supplies operands nobody has seen.
  defp specific_danger("rm", rest, meta) do
    force? = Enum.any?(rest, &(&1 == "--force" or Regex.match?(~r/^-[A-Za-z]*f/, &1)))

    recursive? =
      Enum.any?(rest, &(&1 == "--recursive" or Regex.match?(~r/^-[A-Za-z]*[rR]/, &1)))

    force? or (recursive? and (meta.fed? or Enum.any?(operands(rest), &risky_operand?/1)))
  end

  # Any recursive `chmod`/`chown` (bundles too: `-Rv`), and `chmod 777`.
  defp specific_danger(argv0, rest, _meta) when argv0 in ["chmod", "chown"] do
    Enum.any?(rest, &(&1 == "--recursive" or Regex.match?(~r/^-[A-Za-z]*R/, &1))) or
      (argv0 == "chmod" and "777" in rest)
  end

  # spec 74 BUGS-45: `find ~ -delete` is `rm -r ~`.
  defp specific_danger("find", rest, _meta),
    do: "-delete" in rest and Enum.any?(find_starts(rest), &risky_operand?/1)

  defp specific_danger("git", rest, _meta), do: git_danger(rest)

  defp specific_danger(_argv0, _rest, _meta), do: false

  # The words after the options; after `--`, every word.
  defp operands(words) do
    {before, after_dashes} = Enum.split_while(words, &(&1 != "--"))
    Enum.reject(before, &String.starts_with?(&1, "-")) ++ Enum.drop(after_dashes, 1)
  end

  # spec 74 BUGS-45: an unquoted operand the shell still expands (`$`, a
  # backtick, a glob, a brace), one holding a quote, or one naming something
  # outside the project (`/…`, `~…`, a `..` that climbs out).
  defp risky_operand?(op) do
    String.contains?(op, ["$", "`", "'", "\"", "*", "?", "[", "{"]) or
      String.starts_with?(op, ["/", "~", ".."]) or climbs?(op)
  end

  defp find_starts(words),
    do: Enum.take_while(words, &(not String.starts_with?(&1, ["-", "(", "!"])))

  # spec 74 BUGS-45: `find … -exec CMD {} ;` runs CMD — it is classified as a
  # command, with `{}` standing for what find visits: outside the project when
  # a starting point is (`find ~ -exec rm -r {} +` is `rm -r ~`).
  @find_exec ~w(-exec -execdir -ok -okdir)

  defp find_bodies(words) do
    words
    |> Enum.chunk_while(
      nil,
      fn
        word, nil -> if word in @find_exec, do: {:cont, []}, else: {:cont, nil}
        word, body when word in [";", "+"] -> {:cont, Enum.reverse(body), nil}
        word, body -> {:cont, [word | body]}
      end,
      fn
        nil -> {:cont, nil}
        body -> {:cont, Enum.reverse(body), nil}
      end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp find_class(words, depth) do
    found = if Enum.any?(find_starts(words), &risky_operand?/1), do: "/", else: "./found"

    classes =
      for body <- find_bodies(words) do
        body |> Enum.map_join(" ", &String.replace(&1, "{}", found)) |> classify_at(depth + 1)
      end

    strictest([:normal | classes])
  end

  # spec 74 BUGS-45: git's global options that take a value (`git -C dir`).
  @git_global_values ~w(-C -c --git-dir --work-tree --namespace --config-env --attr-source)

  # spec 74 BUGS-45: a `-c name=value` whose value git runs as a command —
  # `git -c core.pager='rm -rf ~' log`, `git -c alias.x='!rm -rf ~' x` — is
  # classified as the command it is.
  @git_command_keys ~w(.command .cmd .program .driver .clean .smudge .process .textconv .helper
                       .editor .pager .sshcommand .askpass .fsmonitor .external .packobjectshook)

  defp git_config_danger?(words, depth) do
    words
    |> git_configs([])
    |> Enum.any?(fn {key, value} ->
      key = String.downcase(key)

      script =
        cond do
          String.starts_with?(key, "alias.") and String.starts_with?(value, "!") ->
            String.trim_leading(value, "!")

          String.starts_with?(key, "pager.") or String.ends_with?(key, @git_command_keys) ->
            value

          true ->
            nil
        end

      script != nil and classify_at(script, depth + 1) == :dangerous
    end)
  end

  # The `-c name=value` pairs before the subcommand.
  defp git_configs(["-c", pair | rest], acc), do: git_configs(rest, [config_pair(pair) | acc])

  defp git_configs(["-c" <> pair | rest], acc) when pair != "",
    do: git_configs(rest, [config_pair(pair) | acc])

  defp git_configs([flag, _value | rest], acc) when flag in @git_global_values,
    do: git_configs(rest, acc)

  defp git_configs(["-" <> _flag | rest], acc), do: git_configs(rest, acc)
  defp git_configs(_subcommand_and_rest, acc), do: Enum.reverse(acc)

  defp config_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] -> {key, value}
      [key] -> {key, ""}
    end
  end

  # spec 74 BUGS-45: `git -C . push --force` took `.` for the subcommand. The
  # global options that take a value are skipped with their value.

  defp git_subcommand([flag, _value | rest]) when flag in @git_global_values,
    do: git_subcommand(rest)

  defp git_subcommand(["-" <> _flag | rest]), do: git_subcommand(rest)
  defp git_subcommand([sub | rest]), do: {sub, rest}
  defp git_subcommand([]), do: {nil, []}

  defp git_danger(rest) do
    {sub, after_sub} = git_subcommand(rest)
    flags = Enum.filter(rest, &String.starts_with?(&1, "-"))
    args = Enum.reject(after_sub, &String.starts_with?(&1, "-"))

    case sub do
      # spec 74 BUGS-45: `+main` is a force push of one ref, `-uf` a bundled
      # force, `--force-with-lease=main` a spelling of it, and `--mirror` and
      # `--prune` delete remote refs.
      "push" ->
        Enum.any?(
          flags,
          &(long?(&1, ~w(--force --delete --mirror --prune)) or short_has?(&1, ["f", "d"]))
        ) or Enum.any?(args, &(String.contains?(&1, ":") or String.starts_with?(&1, "+")))

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

  # spec 74 BUGS-2: `awk` left — `awk 'BEGIN{system(…)}'` runs anything — and
  # every admitted command checks its flags and operands, not just its name.
  defp safe?(argv0, rest, text), do: not redirects?(rest, text) and command_safe?(argv0, rest)

  defp command_safe?(argv0, rest) when argv0 in @read_only,
    do: flags_safe?(argv0, rest) and operands_inside?(argv0, rest)

  defp command_safe?("find", rest), do: find_safe?(rest)
  defp command_safe?("sed", rest), do: sed_safe?(rest)
  defp command_safe?("git", rest), do: git_safe?(rest)
  defp command_safe?(_argv0, _rest), do: false

  defp redirects?(rest, text),
    do: String.contains?(text, ">") or String.contains?(text, "|&") or "tee" in rest

  # spec 74 BUGS-2: the flags that make a reader write a file or run a program.
  defp flags_safe?("rg", rest),
    do: not Enum.any?(rest, &(long?(&1, ~w(--pre --search-zip)) or short_has?(&1, ["z"])))

  defp flags_safe?("sort", rest),
    do:
      not Enum.any?(
        rest,
        &(long?(&1, ~w(--output --compress-program)) or short_has?(&1, ["o"]))
      )

  defp flags_safe?("uniq", rest), do: length(uniq_operands(rest)) <= 1
  defp flags_safe?("tree", rest), do: not Enum.any?(rest, &short_has?(&1, ["o", "R"]))

  defp flags_safe?("yq", rest),
    do: not Enum.any?(rest, &(long?(&1, ~w(--inplace --split-exp)) or short_has?(&1, ["i", "s"])))

  defp flags_safe?(pager, rest) when pager in ~w(less more),
    do:
      not Enum.any?(
        rest,
        &(long?(&1, ~w(--log-file --LOG-FILE)) or short_has?(&1, ["o", "O"]) or
            String.starts_with?(&1, "+"))
      )

  defp flags_safe?("ag", rest), do: not Enum.any?(rest, &long?(&1, ~w(--pager)))
  defp flags_safe?("file", rest), do: not Enum.any?(rest, &short_has?(&1, ["C"]))
  defp flags_safe?(_argv0, _rest), do: true

  # `--pre`, `--pre=sh`, `--pre-glob …`: the long option or any spelling of it.
  defp long?(token, names), do: Enum.any?(names, &String.starts_with?(token, &1))

  # A short-option bundle (`-o`, `-ro`, `-iP`) naming one of `letters` in its
  # leading run of letters — `-T/tmp/o` is `-T` with a value.
  defp short_has?("-" <> rest, letters) do
    case Regex.run(~r/^[A-Za-z]+/, rest) do
      [run] -> not String.starts_with?(rest, "-") and String.contains?(run, letters)
      nil -> false
    end
  end

  defp short_has?(_token, _letters), do: false

  # `uniq in out` writes `out`; the skip counts are values, not operands.
  defp uniq_operands(rest) do
    rest
    |> Enum.reduce({[], false}, fn
      _value, {acc, true} ->
        {acc, false}

      token, {acc, false} when token in ~w(-f -s -w --skip-fields --skip-chars --check-chars) ->
        {acc, true}

      "-" <> _flag, {acc, false} ->
        {acc, false}

      token, {acc, false} ->
        {[token | acc], false}
    end)
    |> elem(0)
  end

  # spec 74 BUGS-2: an operand that names something outside the project —
  # `/…`, `~…`, a `..` that climbs out, a `$VAR` or a `{…}` expansion — makes a
  # reader `:normal`, as `read_file`'s confinement would refuse it (`cat
  # ~/.ssh/id_rsa`). A flag's `=value` counts as an operand.
  defp operands_inside?(argv0, _rest) when argv0 in @no_file_operands, do: true

  defp operands_inside?(argv0, rest) do
    {flags, operands} = Enum.split_with(rest, &String.starts_with?(&1, "-"))

    operands =
      if argv0 in @pattern_first and not Enum.any?(flags, &long?(&1, @pattern_flags)),
        do: Enum.drop(operands, 1),
        else: operands

    values = for flag <- flags, [_name, value] <- [String.split(flag, "=", parts: 2)], do: value
    not Enum.any?(operands ++ values, &escapes?/1)
  end

  # True when `token`, unquoted, may name a path outside the working directory.
  defp escapes?(token) do
    op = token |> String.replace(["'", "\""], "") |> String.trim_leading("\\")

    op != "/dev/null" and
      (String.starts_with?(op, ["/", "~", "{"]) or String.contains?(op, "$") or climbs?(op))
  end

  defp climbs?(op) do
    op
    |> String.split("/")
    |> Enum.reduce_while(0, fn
      "..", 0 -> {:halt, :out}
      "..", depth -> {:cont, depth - 1}
      segment, depth when segment in ["", "."] -> {:cont, depth}
      _segment, depth -> {:cont, depth + 1}
    end)
    |> Kernel.==(:out)
  end

  # spec 74 BUGS-2: `-okdir` and the `-fprint*`/`-fls` family write files too,
  # and the starting points are operands like any reader's.
  defp find_safe?(rest) do
    starts = Enum.take_while(rest, &(not String.starts_with?(&1, ["-", "(", "!"])))

    not Enum.any?(
      rest,
      &(&1 in ~w(-delete -exec -execdir -ok -okdir -fls) or String.starts_with?(&1, "-fprint"))
    ) and not Enum.any?(starts, &escapes?/1)
  end

  # spec 74 BUGS-2: only `-n` (and `-e SCRIPT`), and every script a line-address
  # print. `-i`, `-I`, `-Ei`, `s///w`, `e`, `r`, `w` — nothing else is a read.
  defp sed_safe?(rest) do
    case sed_parse(rest, [], [], false) do
      {:ok, scripts, files, true} ->
        scripts != [] and Enum.all?(scripts, &Regex.match?(@sed_print, sed_unquote(&1))) and
          not Enum.any?(files, &escapes?/1)

      _other ->
        false
    end
  end

  defp sed_parse([], scripts, files, quiet?),
    do: {:ok, Enum.reverse(scripts), Enum.reverse(files), quiet?}

  defp sed_parse(["-n" | rest], scripts, files, _quiet?),
    do: sed_parse(rest, scripts, files, true)

  defp sed_parse(["-e", script | rest], scripts, files, quiet?),
    do: sed_parse(rest, [script | scripts], files, quiet?)

  defp sed_parse(["--" | rest], scripts, files, quiet?),
    do: sed_parse_operands(rest, scripts, files, quiet?)

  defp sed_parse(["-" <> _other | _rest], _scripts, _files, _quiet?), do: :error

  defp sed_parse(operands, scripts, files, quiet?),
    do: sed_parse_operands(operands, scripts, files, quiet?)

  # The first operand is the script unless `-e` gave one; the rest are files.
  defp sed_parse_operands([script | files], [], acc, quiet?),
    do: {:ok, [script], Enum.reverse(acc) ++ files, quiet?}

  defp sed_parse_operands(files, scripts, acc, quiet?),
    do: {:ok, Enum.reverse(scripts), Enum.reverse(acc) ++ files, quiet?}

  defp sed_unquote(script),
    do: script |> String.replace(["'", "\""], "") |> String.replace("\\$", "$")

  # spec 74 BUGS-2: the options that run a program (`--ext-diff`,
  # `--textconv`, `--exec-path`), set config (`-c`, `--config-env`), write a
  # file (`--output`) or move git to another repository and its config
  # (`-C`, `--git-dir`, `--work-tree`) — a nested `.git/config` is not under
  # the protected-path check, and its `core.fsmonitor` runs on `status`.
  @git_unsafe_long ~w(--output --ext-diff --textconv --config-env --exec-path --git-dir
                      --work-tree --no-index)

  defp git_safe?(rest) do
    rest = Enum.reject(rest, &(&1 == "--"))
    sub = Enum.find(rest, &(not String.starts_with?(&1, "-")))
    flags = Enum.filter(rest, &String.starts_with?(&1, "-"))
    args = rest |> Enum.reject(&String.starts_with?(&1, "-")) |> Enum.drop(1)

    # spec 73 T18: explicit read forms for the subcommands that also write.
    read? =
      case sub do
        "stash" ->
          List.first(args) in ["list", "show"]

        "remote" ->
          args == [] or List.first(args) in ["show", "get-url"]

        "config" ->
          "--global" not in flags and Enum.any?(flags, &(&1 in @git_config_reads))

        "tag" ->
          args == [] or "-l" in flags or "--list" in flags

        "branch" ->
          (args == [] or "-l" in flags or "--list" in flags) and not branch_write?(flags)

        _read ->
          sub in @git_read
      end

    values = for flag <- flags, [_name, value] <- [String.split(flag, "=", parts: 2)], do: value

    read? and not Enum.any?(flags, &(&1 in ["-c", "-C"] or long?(&1, @git_unsafe_long))) and
      not Enum.any?(args ++ values, &git_escapes?/1)
  end

  # A path operand outside the project: `git log -- /etc`, the value of
  # `git blame --contents ~/.ssh/id_rsa x`. A revision range (`..main`,
  # `HEAD..x`) is not a path, so only a `../` climbs.
  defp git_escapes?(arg) do
    op = String.replace(arg, ["'", "\""], "")
    String.starts_with?(op, ["/", "~", "$"]) or String.contains?(op, "../")
  end

  defp branch_write?(flags) do
    Enum.any?(flags, fn flag ->
      Enum.any?(@git_branch_writes, &(flag == &1 or String.starts_with?(flag, &1 <> "=")))
    end)
  end

  # ------------------------------------------------------------------ prefix (T5)

  # A driver that does nothing on its own: its whole meaning is in what follows,
  # so a family of just this word would be an approval of the driver (spec 67 B5).
  @drivers ~w(rm mv cp chmod chown kill git npm pnpm yarn docker kubectl gh cargo mix sh bash zsh)

  # These take operands, not subcommands: every word after the flags is a file,
  # and a file is never part of a family (`cp -r src dst` is the `cp -r`
  # family, not the `cp -r dst` one).
  @operand_only ~w(rm mv cp chmod chown chgrp ln touch mkdir rmdir kill dd)

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

  # spec 74 BUGS-45: a family is only as wide as its words are literal. A
  # `$VAR`, a quote or a glob in an operand-only command (`rm -r $HOME`),
  # operands `xargs` supplies, or a wrapper option that writes (`time -o x`)
  # gives no family at all; an assignment in front of the command is part of
  # the family (`MIX_ENV=test mix test`), so an approved `mix test` never
  # covers `PATH=/tmp/x:$PATH mix test`.
  defp single_prefix(segment) do
    with false <- Regex.match?(@substitution, segment),
         {[argv0 | rest], meta} <- peel(words(segment), 0, @meta),
         false <- meta.unsafe?,
         true <- literal?(argv0) and Enum.all?(meta.assignments, &literal?/1),
         false <- base(argv0) in @operand_only and not Enum.all?(rest, &literal?/1),
         tokens = family_tokens(argv0, rest),
         false <- tokens == [] and base(argv0) in @drivers do
      Enum.join(Enum.reverse(meta.assignments) ++ [argv0 | tokens], " ")
    else
      _other -> ""
    end
  end

  # A word the shell passes on exactly as written: no quote, `$`, backslash,
  # glob, brace, tilde or parenthesis.
  defp literal?(word), do: Regex.match?(~r/^[\p{L}\p{N}._\/+,:@%=-]+$/u, word)

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
