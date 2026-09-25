defmodule SwarmCodeCLI.Release do
  @moduledoc """
  Entry point for the packaged SwarmCode terminal client.

  `rel/overlays/bin/swarmcode` parses the command line itself: the
  full-screen view starts the release (`bin/swarm_code_cli start`) and the
  headless modes evaluate `SwarmCodeCLI.Release.main(System.argv())` with
  `-p PROMPT [--json]` or `--plain [--ndjson]`. The same grammar is accepted
  here so the release can also be driven directly; `parse/1` is that grammar.

  Exit codes: 0 done, 1 the run failed, 2 usage, 3 startup refused.
  """

  alias SwarmCodeCLI.Release.Headless

  @compile {:no_warn_undefined, [SwarmCode.Domain.Paths]}

  @usage """
  Usage: swarmcode [DIR] [--new | --continue | --resume ID] [--model M]
                   [-p PROMPT [--json]] [--plain [--ndjson]] [--help] [--version]
         swarmcode settings [QUERY] [--dir DIR]
         swarmcode config COMMAND [ARGS]     (swarmcode config help lists them)

  Opens the saved session for DIR (default: the current directory).

    settings [QUERY]  open Settings, at QUERY when given ('swarmcode settings providers');
                      it opens even when no model provider is set up yet
    config COMMAND    read and change settings from scripts, dotfiles and SSH
                      (a folder named settings or config: swarmcode ./settings, ./config)

    --new           start a new conversation
    --continue, -c  continue the latest conversation (the default)
    --resume ID     open the conversation with this id
    --model M       use model M (or provider/model) for this session only
    -p PROMPT       run one turn without the full-screen view, print the answer and
                    exit; approvals nobody can give are denied and said on stderr.
                    PROMPT - reads the prompt from stdin
    --json          with -p: print one JSON object instead of the streamed answer
    --plain         line-by-line presenter for pipes, CI and SSH (type `help`)
    --ndjson        with --plain: one JSON record per line
    --help, -h      this text
    --version, -V   the version

  Exit codes: 0 done, 1 the run failed, 2 usage, 3 startup refused.
  Keys in the full-screen view: Ctrl-P palette, ? every key, Esc stops a turn,
  Ctrl-F opens an agent from the side panel, Ctrl-B its shape, Ctrl-C twice quits.
  The mouse wheel scrolls the pane under the pointer; Shift-drag (Option-drag in
  Terminal.app and iTerm2) still selects text, and /mouse off gives the
  terminal its own selection back.
  """

  # The prompt's size is the composer's: one paste.
  @max_prompt_bytes 262_144

  @type options :: %{
          mode: :tui | :plain | :prompt | :settings,
          project: binary() | nil,
          conversation: binary() | nil,
          model: binary() | nil,
          prompt: binary() | nil,
          format: :text | :json | :ndjson
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
    code = run(args)
    System.halt(code)
  end

  @doc "Runs the command line and returns the exit code (the VM keeps running)."
  @spec run([binary()]) :: 0 | 1 | 2 | 3 | 4
  def run(args) do
    case parse(args) do
      {:config, rest} ->
        SwarmCodeCLI.Release.ConfigCommand.run(rest)

      :help ->
        IO.write(@usage)
        0

      :version ->
        IO.puts("swarmcode " <> version())
        0

      {:error, message} ->
        IO.puts(:stderr, "swarmcode: " <> message <> " Run 'swarmcode --help'.")
        2

      {:ok, %{mode: mode}} when mode in [:tui, :settings] ->
        IO.puts(
          :stderr,
          "swarmcode: the full-screen view starts from the swarmcode command, not from eval. " <>
            "Use -p or --plain here."
        )

        2

      {:ok, options} ->
        with {:ok, options} <- read_prompt(options) do
          Headless.run(mode(options), headless_options(options))
        else
          {:error, message} ->
            IO.puts(:stderr, "swarmcode: " <> message)
            2
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

  defp settings([], words, dir),
    do:
      {:ok,
       %{
         mode: :settings,
         project: dir,
         conversation: nil,
         model: nil,
         prompt: nil,
         format: :text,
         query: words |> Enum.reverse() |> Enum.join(" ")
       }}

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

      flag when flag in ["--version", "-V"] ->
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
  defp flag_name(key), do: "--" <> Atom.to_string(key)

  defp validate(parsed) do
    cond do
      parsed.json? and parsed.prompt == nil ->
        {:error, "--json goes with -p."}

      parsed.ndjson? and not parsed.plain? ->
        {:error, "--ndjson goes with --plain."}

      parsed.plain? and parsed.prompt != nil ->
        {:error, "-p and --plain do not go together."}

      parsed.model != nil and String.trim(parsed.model) == "" ->
        {:error, "--model needs a model name."}

      parsed.conversation not in [nil, "new", "latest"] and not uuid?(parsed.conversation) ->
        # pass70 Q19: an eight-digit prefix is an id to a person; say what
        # is missing and where the ids are.
        {:error, "--resume needs a whole conversation id; /resume inside swarmcode picks one."}

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
           format: format
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

  # `-p -` reads the prompt from stdin, bounded like any prompt.
  defp read_prompt(%{mode: :prompt, prompt: "-"} = options) do
    case IO.binread(:stdio, @max_prompt_bytes + 1) do
      text when is_binary(text) ->
        if prompt?(text),
          do: {:ok, %{options | prompt: text}},
          else: {:error, "the prompt on stdin is empty, not UTF-8, or over 256 KiB."}

      _ ->
        {:error, "the prompt on stdin is empty."}
    end
  end

  defp read_prompt(options), do: {:ok, options}

  defp mode(%{mode: :prompt, prompt: prompt, format: format}), do: {:prompt, prompt, format}
  defp mode(%{mode: :plain, format: format}), do: {:plain, format}

  defp headless_options(options) do
    [
      project_root: options.project && Path.expand(options.project),
      conversation: options.conversation,
      model: options.model
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
