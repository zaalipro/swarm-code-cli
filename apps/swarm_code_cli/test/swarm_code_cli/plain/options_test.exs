defmodule SwarmCodeCLI.Plain.OptionsTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.Plain.{Options, Environment}

  test "TTY selection and closed flags retain degraded preferences" do
    environment = %Environment{
      stdin_tty?: true,
      stdout_tty?: true,
      controlling_tty?: true,
      term: "xterm"
    }

    assert {:ok, %{plain?: false, no_alt_screen?: true}} =
             Options.select(["--no-alt-screen"], environment)

    for field <- [:stdin_tty?, :stdout_tty?, :controlling_tty?] do
      assert {:ok, %{plain?: true}} = Options.select([], Map.put(environment, field, false))
    end

    assert {:ok, %{plain?: true}} = Options.select([], %{environment | term: "DuMb"})

    assert {:ok, %{ascii?: true, color?: false, reduced_motion?: true, ambiguous_width: :wide}} =
             Options.select(["--ascii", "--reduced-motion", "--ambiguous-width=wide"], %{
               environment
               | no_color?: true
             })

    for arguments <- [["--wat"], ["--ascii", "--ascii"], ["--ambiguous-width=huge"]] do
      assert {:error, :invalid_option} = Options.select(arguments, environment)
    end
  end
end
