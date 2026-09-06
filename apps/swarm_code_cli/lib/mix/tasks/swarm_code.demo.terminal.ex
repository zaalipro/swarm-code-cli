defmodule Mix.Tasks.SwarmCode.Demo.Terminal do
  use Mix.Task
  @shortdoc "Runs the guarded interactive fake terminal demo"
  @moduledoc """
  Run `scripts/dev/run_terminal_demo.sh` from the checkout. This starts a fixed
  synthetic workspace; it does not load user data. Tab moves focus, Enter activates,
  Escape returns to content, and q detaches outside the editor. Dirty drafts use
  the existing Cancel/Confirm dialog. Ctrl-Z remains editor undo; shell job-control
  suspend is not provided by this demo.

  Options: `--no-alt-screen`, `--ascii`, `--monochrome`,
  `--ambiguous-width narrow|wide`, and `--reduced-motion`.
  """
  @requirements ["compile"]
  alias SwarmCodeCLI.UI.{Capabilities, Size}

  @impl true
  def run(args) do
    unless Mix.Project.config()[:app] == :swarm_code_cli and not Mix.Project.umbrella?(),
      do: Mix.raise("Run scripts/dev/run_terminal_demo.sh")

    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          no_alt_screen: :boolean,
          ascii: :boolean,
          monochrome: :boolean,
          ambiguous_width: :string,
          reduced_motion: :boolean
        ]
      )

    unless rest == [] and invalid == [] and
             length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
             Keyword.get(options, :ambiguous_width, "narrow") in ["narrow", "wide"],
           do:
             Mix.raise(
               "Expected terminal options: --no-alt-screen --ascii --monochrome --ambiguous-width narrow|wide --reduced-motion"
             )

    unless :init.get_argument(:noinput) != :error,
      do: Mix.raise("Run scripts/dev/run_terminal_demo.sh (requires -noinput)")

    unless :prim_tty.isatty(:stdin) == true and :prim_tty.isatty(:stdout) == true and
             System.get_env("TERM") not in [nil, "", "dumb"],
           do:
             Mix.raise(
               "Terminal unavailable. Run (cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)"
             )

    mode =
      cond do
        Keyword.get(options, :monochrome, false) or System.get_env("NO_COLOR") != nil ->
          :monochrome

        System.get_env("COLORTERM") in ["truecolor", "24bit"] ->
          :truecolor

        String.contains?(System.get_env("TERM"), "256color") ->
          :ansi256

        true ->
          :ansi16
      end

    caps = %Capabilities{
      size: %Size{columns: 80, rows: 24},
      stdin_tty?: true,
      stdout_tty?: true,
      color_mode: mode,
      ascii?: Keyword.get(options, :ascii, false),
      reduced_motion?: Keyword.get(options, :reduced_motion, false),
      ambiguous_width: if(options[:ambiguous_width] == "wide", do: :wide, else: :narrow)
    }

    flags = %{
      alternate?: not Keyword.get(options, :no_alt_screen, false),
      focus?: true,
      paste?: true
    }

    executable = Path.expand("../../_build/terminal-port/debug/swarm-terminal-port")
    unless File.regular?(executable), do: Mix.raise("Build the guarded terminal port first")

    {result, audit} =
      SwarmCodeCLI.Demo.ApplicationFence.run(
        fn ->
          SwarmCodeCLI.Demo.Terminal.run(caps, flags, executable)
        end,
        timeout: :infinity
      )

    SwarmCodeCLI.Demo.ApplicationFence.maybe_write_fd3(audit)
    if result != :ok, do: Mix.raise("Terminal demo failed")
    :ok
  end
end
