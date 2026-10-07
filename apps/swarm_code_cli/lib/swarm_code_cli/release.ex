defmodule SwarmCodeCLI.Release do
  @moduledoc """
  Entry point for the packaged SwarmCode terminal client.

  `rel/overlays/bin/ncode` parses the command line itself: the
  full-screen view starts the release (`bin/swarm_code_cli start`) and the
  headless modes evaluate `SwarmCodeCLI.Release.main(System.argv())` with
  `-p PROMPT [--json]` or `--plain [--ndjson]`. The same grammar is accepted
  here so the release can also be driven directly; `parse/1` is that grammar.

  Exit codes: 0 done, 1 the run failed, 2 usage, 3 startup refused.
  """

  alias SwarmCodeCLI.Release.Headless

  @compile {:no_warn_undefined, [SwarmCode.Domain.Paths]}

  @usage """
  Usage: ncode [DIR] [--new | --continue | --resume ID] [--model M]
               [-p PROMPT [--json] [--fail-on-denied]] [--plain [--ndjson]]
         ncode settings [QUERY] [--dir DIR]
         ncode config COMMAND [ARGS]     (ncode config help lists them)
         ncode help | version | doctor

  Opens the saved session for DIR (default: the current directory).

    settings [QUERY]  open Settings, at QUERY when given ('ncode settings providers');
                      it opens even when no model provider is set up yet
    config COMMAND    read and change settings from scripts, dotfiles and SSH
    doctor            check the install, the providers and the database (config doctor)
                      (a folder with one of these names: ncode ./settings, ./config)

    --new             start a new conversation
    --continue, -c    continue the latest conversation (the default)
    --resume, -r ID   open the conversation with this id
    --model, -m M     use model M (or provider/model) for this session only
    -p PROMPT         run one turn without the full-screen view, print the answer
                      and exit; approvals nobody can give are denied, and one
                      stderr line says which. PROMPT - reads the prompt from stdin;
                      with a PROMPT, piped stdin is sent after it
    --json            with -p: print one JSON object instead of the streamed answer
    --fail-on-denied  with -p or --plain: exit 1 when a tool call was denied
    --plain           line-by-line presenter for pipes, CI and SSH (type `help`)
    --ndjson          with --plain: one JSON record per line
    --help, -h        this text
    --version, -V, -v the version

  Examples:
    ncode
    ncode -p "explain this repo" --json
    ncode settings providers
    ncode config doctor

  Exit codes: 0 done, 1 the run failed, 2 usage, 3 startup refused,
  4 changed elsewhere (ncode config), 129/143 closed by SIGHUP/SIGTERM.
  Keys in the full-screen view: Ctrl-P palette, ? every key, Esc stops a turn,
  Ctrl-F opens an agent from the side panel, Ctrl-B its shape, Ctrl-C twice quits.
  """

  # The prompt's size is the composer's: one paste.
  @max_prompt_bytes 262_144

  @type options :: %{
          mode: :tui | :plain | :prompt | :settings,
          project: binary() | nil,
          conversation: binary() | nil,
          model: binary() | nil,
          prompt: binary() | nil,
          format: :text | :json | :ndjson,
          fail_on_denied: boolean()
        }

  @doc """
  The CLI preferences file (pass 72, P6): `cli.json` in the SwarmCode config
  directory, beside the database. nil when the domain is not loaded.
  """
  @spec preferences_path() :: Path.t() | nil
  def preferences_path do
    Path.join(SwarmCode.Domain.Paths.config_dir(), "cli.json")
  rescue
    _ -> nil
  end

  @doc "Runs the command line and halts the VM with its exit code."
  def main(["tui"]), do: SwarmCodeCLI.Release.PersistedSession.run()

  def main(args) when is_list(args) do
    # cli020 B2: the headless output and the prompt on stdin are UTF-8 whatever
    # the locale says (under LANG=C the devices start as latin1).
    configure_io()
    # cli020 B9: SIGTERM and SIGHUP close the session the normal way.
    if headless_args?(args), do: SwarmCodeCLI.Release.Signals.install(self())
    code = run(args)
    flush_logs()
    System.halt(code)
  end

  @doc """
  cli020 B15 (onboarding-3): writes what the log handler still buffers before
  the VM halts (a halt drops it, so cli.log stayed empty after a failure).
  Bounded: a log that cannot be written within `timeout` is left as it is.
  """
  @spec flush_logs(non_neg_integer()) :: :ok
  def flush_logs(timeout \\ 2_000) do
    {pid, ref} =
      spawn_monitor(fn ->
        _ = Logger.flush()
        _ = :logger_std_h.filesync(:default)
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        :ok
    end
  end

  @doc """
  cli020 B2: puts the standard devices in unicode mode, so a `-p` answer, a
  `--json` summary and a prompt read from stdin keep their UTF-8 under
  `LC_ALL=C` (the VM opens them as latin1 there).
  """
  @spec configure_io([atom() | pid()]) :: :ok
  def configure_io(devices \\ [:standard_io, :standard_error]) do
    Enum.each(devices, fn device ->
      try do
        :io.setopts(device, encoding: :unicode)
      catch
        _, _ -> :ok
      end
    end)
  end

  defp headless_args?(["config" | _]), do: false

  defp headless_args?(args),
    do: Enum.any?(args, &(&1 in ["-p", "--prompt", "--print", "--plain"]))

  @doc "Runs the command line and returns the exit code (the VM keeps running)."
  @spec run([binary()]) :: 0 | 1 | 2 | 3 | 4 | 129 | 143
  def run(args) do
    case parse(args) do
      {:config, rest} ->
        SwarmCodeCLI.Release.ConfigCommand.run(rest)

      :help ->
        IO.write(@usage)
        0

      :version ->
        IO.puts("ncode " <> version())
        0

      {:error, message} ->
        IO.puts(:stderr, "ncode: " <> message <> " Run 'ncode --help'.")
        2

      {:ok, %{mode: mode}} when mode in [:tui, :settings] ->
        IO.puts(
          :stderr,
          "ncode: the full-screen view starts from the ncode command, not from eval. " <>
            "Use -p or --plain here."
        )

        2

      {:ok, options} ->
        with {:ok, options} <- read_prompt(options) do
          Headless.run(mode(options), headless_options(options))
        else
          {:error, message} ->
            IO.puts(:stderr, "ncode: " <> message)
            Headless.json_failure(options.format, message, 2)
        end
    end
  end

  @doc "The usage text."
  def usage, do: @usage

  @doc """
  Parses the command line.

  Returns `:help`, `:version`, `{:error, message}` for a usage error, or
  `{:ok, options}`. A flag given twice, a missing value, `--json` without
  `-p`, `--ndjson` without `--plain`, `-p` with `--plain`, two conversation
  choices or two directories are usage errors.
  """
  @spec parse([binary()]) ::
          :help | :version | {:error, binary()} | {:ok, options()} | {:config, [binary()]}
  # pass74 S1-13/S1-14: the first word `settings` or `config` is the
  # subcommand (a folder of that name opens with ./settings or -- settings).
  def parse(["config" | rest]), do: {:config, rest}
  # cli020 B16: the conventional words.
  def parse(["help" | _]), do: :help
  def parse(["version" | _]), do: :version
  def parse(["doctor" | rest]), do: {:config, ["doctor" | rest]}
  def parse(["settings" | rest]), do: settings(rest, [], nil)

  def parse(args) when is_list(args) do
    initial = %{
      mode: :tui,
      project: nil,
      conversation: nil,
      model: nil,
      prompt: nil,
      json?: false,
      plain?: false,
      ndjson?: false,
      fail_on_denied?: false,
      seen: MapSet.new()
    }

    with {:ok, parsed} <- flags(args, initial) do
      cond do
        :help in parsed.seen -> :help
        :version in parsed.seen -> :version
        true -> validate(parsed)
      end
    end
  end

  defp settings([], words, dir) do
    query = words |> Enum.reverse() |> Enum.join(" ")

    if byte_size(query) > 200,
      do: {:error, "the settings query is too long (200 bytes at most)."},
      else:
        {:ok,
         %{
           mode: :settings,
           project: dir,
           conversation: nil,
           model: nil,
           prompt: nil,
           format: :text,
           query: query
         }}
  end

  defp settings([flag | _], _words, _dir) when flag in ["--help", "-h"], do: :help

  defp settings(["--dir" <> _ | _], _words, dir) when dir != nil,
    do: {:error, "name one directory at most."}

  defp settings(["--dir", dir | rest], words, nil) when dir != "--",
    do: settings(rest, words, dir)

  defp settings(["--dir=" <> dir | rest], words, nil), do: settings(rest, words, dir)
  defp settings(["--dir" | _], _words, _dir), do: {:error, "--dir needs a value."}

  defp settings(["-" <> _ = flag | _], _words, _dir) when flag != "-",
    do: {:error, "settings takes a query and --dir only."}

  defp settings([word | rest], words, dir), do: settings(rest, [word | words], dir)

  defp flags([], parsed), do: {:ok, parsed}

  defp flags([flag | rest], parsed) do
    case flag do
      # Help and the version answer at once, as the launcher does.
      flag when flag in ["--help", "-h"] ->
        {:ok, %{parsed | seen: MapSet.put(parsed.seen, :help)}}

      flag when flag in ["--version", "-V", "-v"] ->
        {:ok, %{parsed | seen: MapSet.put(parsed.seen, :version)}}

      "--new" ->
        conversation(parsed, "new", rest)

      flag when flag in ["--continue", "-c"] ->
        conversation(parsed, "latest", rest)

      "--resume=" <> id ->
        conversation(parsed, id, rest)

      flag when flag in ["--resume", "-r"] ->
        value(flag, rest, fn id, rest -> conversation(parsed, id, rest) end)

      "--model=" <> model ->
        once(parsed, :model, rest, &%{&1 | model: model})

      flag when flag in ["--model", "-m"] ->
        value(flag, rest, fn model, rest -> once(parsed, :model, rest, &%{&1 | model: model}) end)

      "--prompt=" <> prompt ->
        once(parsed, :prompt, rest, &%{&1 | prompt: prompt})

      flag when flag in ["-p", "--prompt", "--print"] ->
        value(flag, rest, fn prompt, rest ->
          once(parsed, :prompt, rest, &%{&1 | prompt: prompt})
        end)

      "--json" ->
        once(parsed, :json, rest, &%{&1 | json?: true})

      "--plain" ->
        once(parsed, :plain, rest, &%{&1 | plain?: true})

      "--ndjson" ->
        once(parsed, :ndjson, rest, &%{&1 | ndjson?: true})

      "--fail-on-denied" ->
        once(parsed, :fail_on_denied, rest, &%{&1 | fail_on_denied?: true})

      "--" ->
        directories(rest, parsed)

      "-" <> _ = flag when flag != "-" ->
        {:error, "unknown option '#{flag}'."}

      directory ->
        directory(parsed, directory, rest)
    end
  end

  defp directories([], parsed), do: {:ok, parsed}

  defp directories([directory | rest], parsed) do
    with {:ok, parsed} <- set_directory(parsed, directory), do: directories(rest, parsed)
  end

  defp directory(parsed, directory, rest) do
    with {:ok, parsed} <- set_directory(parsed, directory), do: flags(rest, parsed)
  end

  defp set_directory(%{project: nil} = parsed, directory),
    do: {:ok, %{parsed | project: directory}}

  defp set_directory(_, _), do: {:error, "name one directory at most."}

  defp value(_flag, [value | rest], continue) when value != "--", do: continue.(value, rest)
  defp value(flag, _, _), do: {:error, "#{flag} needs a value."}

  defp conversation(%{conversation: nil} = parsed, value, rest),
    do: flags(rest, %{parsed | conversation: value})

  defp conversation(_, _, _),
    do: {:error, "choose one of --new, --continue and --resume."}

  defp once(parsed, key, rest, update) do
    if MapSet.member?(parsed.seen, key),
      do: {:error, "#{flag_name(key)} is given twice."},
      else: flags(rest, update.(%{parsed | seen: MapSet.put(parsed.seen, key)}))
  end

  defp flag_name(:prompt), do: "-p"
  defp flag_name(:fail_on_denied), do: "--fail-on-denied"
  defp flag_name(key), do: "--" <> Atom.to_string(key)

  defp validate(parsed) do
    cond do
      parsed.json? and parsed.prompt == nil ->
        {:error, "--json goes with -p."}

      parsed.ndjson? and not parsed.plain? ->
        {:error, "--ndjson goes with --plain."}

      parsed.plain? and parsed.prompt != nil ->
        {:error, "-p and --plain do not go together."}

      parsed.fail_on_denied? and parsed.prompt == nil and not parsed.plain? ->
        {:error, "--fail-on-denied goes with -p or --plain."}

      parsed.model != nil and String.trim(parsed.model) == "" ->
        {:error, "--model needs a model name."}

      parsed.conversation not in [nil, "new", "latest"] and not uuid?(parsed.conversation) ->
        # pass70 Q19: an eight-digit prefix is an id to a person; say what
        # is missing and where the ids are.
        {:error, "--resume needs a whole conversation id; /resume inside ncode picks one."}

      parsed.prompt != nil and parsed.prompt != "-" and not prompt?(parsed.prompt) ->
        {:error, "-p needs a prompt of at most 256 KiB."}

      true ->
        mode =
          cond do
            parsed.prompt != nil -> :prompt
            parsed.plain? -> :plain
            true -> :tui
          end

        format =
          cond do
            parsed.json? -> :json
            parsed.ndjson? -> :ndjson
            true -> :text
          end

        {:ok,
         %{
           mode: mode,
           project: parsed.project,
           conversation: parsed.conversation,
           model: parsed.model,
           prompt: parsed.prompt,
           format: format,
           fail_on_denied: parsed.fail_on_denied?
         }}
    end
  end

  defp uuid?(value),
    do:
      Regex.match?(
        ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i,
        value
      )

  defp prompt?(text),
    do: byte_size(text) <= @max_prompt_bytes and String.valid?(text) and String.trim(text) != ""

  @doc """
  cli020 B1: the prompt `-p -` reads from stdin, and the piped stdin a `-p
  PROMPT` gets when the launcher saw a pipe or a file there
  (`SWARM_STDIN_PIPED=1`). Both are read in unicode mode (B2) and bounded to
  256 KiB in bytes.
  """
  @spec read_prompt(map(), atom() | pid(), map()) :: {:ok, map()} | {:error, String.t()}
  def read_prompt(options, device \\ :stdio, env \\ System.get_env())

  def read_prompt(%{mode: :prompt, prompt: "-"} = options, device, _env) do
    case read_stdin(device) do
      {:ok, text} ->
        if String.trim(text) == "",
          do: {:error, "the prompt on stdin is empty."},
          else: {:ok, %{options | prompt: text}}

      {:error, :empty} ->
        {:error, "the prompt on stdin is empty."}

      {:error, :unicode} ->
        {:error, "the prompt on stdin is not UTF-8."}

      {:error, :too_large} ->
        {:error, "the prompt on stdin is over 256 KiB."}
    end
  end

  def read_prompt(%{mode: :prompt, prompt: prompt} = options, device, env)
      when is_binary(prompt) do
    if Map.get(env, "SWARM_STDIN_PIPED") == "1" do
      case read_stdin(device) do
        {:ok, stdin} ->
          if String.trim(stdin) == "",
            do: {:ok, options},
            else: piped(options, prompt <> "\n\n<stdin>\n" <> stdin <> "\n</stdin>")

        {:error, :empty} ->
          {:ok, options}

        {:error, :unicode} ->
          {:error, "the prompt on stdin is not UTF-8."}

        {:error, :too_large} ->
          {:error, "the prompt and its piped stdin are over 256 KiB."}
      end
    else
      {:ok, options}
    end
  end

  def read_prompt(options, _device, _env), do: {:ok, options}

  defp piped(options, text) do
    if byte_size(text) <= @max_prompt_bytes,
      do: {:ok, %{options | prompt: text}},
      else: {:error, "the prompt and its piped stdin are over 256 KiB."}
  end

  # A unicode device counts characters, so the byte bound is checked again.
  defp read_stdin(device) do
    case IO.read(device, @max_prompt_bytes + 1) do
      :eof ->
        {:error, :empty}

      text when is_binary(text) and byte_size(text) > @max_prompt_bytes ->
        {:error, :too_large}

      text when is_binary(text) ->
        if String.valid?(text), do: {:ok, text}, else: {:error, :unicode}

      {:error, _} ->
        {:error, :unicode}
    end
  end

  defp mode(%{mode: :prompt, prompt: prompt, format: format}), do: {:prompt, prompt, format}
  defp mode(%{mode: :plain, format: format}), do: {:plain, format}

  defp headless_options(options) do
    [
      project_root: options.project && Path.expand(options.project),
      conversation: options.conversation,
      model: options.model,
      fail_on_denied: Map.get(options, :fail_on_denied) == true || nil
    ]
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
  end

  defp version do
    Application.load(:swarm_code_cli)

    case Application.spec(:swarm_code_cli, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
