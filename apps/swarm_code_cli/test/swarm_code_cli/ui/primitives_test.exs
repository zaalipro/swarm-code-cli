defmodule SwarmCodeCLI.UI.PrimitivesTest do
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Size}
  alias SwarmCodeCLI.UI.Capabilities.Probe

  test "size accepts only positive integer dimensions" do
    assert {:ok, %Size{columns: 120, rows: 40}} = Size.new(120, 40)

    for dimensions <- [{0, 40}, {120, 0}, {-1, 40}, {120, -1}, {120.0, 40}, {120, "40"}] do
      assert {:error, :invalid_size} = Size.new(elem(dimensions, 0), elem(dimensions, 1))
    end
  end

  test "minimal trusted text cannot be confused with a raw binary" do
    safe = SafeText.chrome(:fake_banner)
    assert SafeText.value(safe) == "FAKE DEMO — NO USER DATA"
    refute safe == "FAKE DEMO — NO USER DATA"
    assert_raise FunctionClauseError, fn -> apply(SafeText, :chrome, ["untrusted"]) end
  end

  test "trusted chrome is a fixed closed catalogue" do
    assert SafeText.value(SafeText.chrome(:empty)) == ""
    assert SafeText.value(SafeText.chrome(:main)) == "Main"
    assert SafeText.value(SafeText.chrome(:help)) == "Help"
    assert SafeText.value(SafeText.chrome(:detach)) == "Detach"
    assert SafeText.value(SafeText.chrome(:plain)) == "Plain"
  end

  test "safe text inspection never discloses its value" do
    inspected = inspect(SafeText.chrome(:fake_banner))

    assert inspected == "#SwarmCodeCLI.UI.SafeText<...>"
    refute inspected =~ "FAKE"
  end

  test "capability shape distinguishes input, output, and controlling TTY" do
    size = %Size{columns: 120, rows: 40}

    caps =
      Capabilities.explicit(size,
        stdin_tty?: true,
        stdout_tty?: true,
        controlling_tty?: true
      )

    assert caps.stdin_tty? and caps.stdout_tty? and caps.controlling_tty?
    assert caps.ambiguous_width == :narrow
    assert caps.mouse == :unavailable
    assert caps.paste_preallocation_bound? == false
  end

  test "explicit capabilities accept every closed final-shaped option" do
    size = %Size{columns: 80, rows: 24}

    assert %Capabilities{
             size: ^size,
             color_mode: :ansi256,
             ambiguous_width: :wide,
             ascii?: true,
             reduced_motion?: true,
             tty?: true,
             controlling_tty?: true,
             stdin_tty?: true,
             stdout_tty?: true,
             full_screen?: true,
             enhanced_keys: :supported,
             focus: :best_effort,
             paste: :supported,
             mouse: :unavailable,
             alternate_screen: :best_effort,
             paste_preallocation_bound?: true
           } =
             Capabilities.explicit(size,
               color_mode: :ansi256,
               ambiguous_width: :wide,
               ascii?: true,
               reduced_motion?: true,
               tty?: true,
               controlling_tty?: true,
               stdin_tty?: true,
               stdout_tty?: true,
               full_screen?: true,
               enhanced_keys: :supported,
               focus: :best_effort,
               paste: :supported,
               mouse: :unavailable,
               alternate_screen: :best_effort,
               paste_preallocation_bound?: true
             )
  end

  test "explicit capabilities reject values outside their closed sets" do
    size = %Size{columns: 80, rows: 24}

    for options <- [
          [color_mode: :millions],
          [ambiguous_width: :auto],
          [ascii?: :yes],
          [enhanced_keys: :maybe],
          [mouse: :supported],
          [mouse: :unavailable, mouse: :supported],
          [unknown: true]
        ] do
      assert_raise ArgumentError, fn -> Capabilities.explicit(size, options) end
    end
  end

  test "capability construction is deterministic and does not consult the environment" do
    size = %Size{columns: 80, rows: 24}
    before = Capabilities.explicit(size, [])
    previous = System.get_env("NO_COLOR")

    try do
      System.put_env("NO_COLOR", "1")
      assert Capabilities.explicit(size, []) == before
    after
      if previous, do: System.put_env("NO_COLOR", previous), else: System.delete_env("NO_COLOR")
    end
  end

  test "probe is inert observation data" do
    assert %Probe{
             size: nil,
             stdin_tty?: false,
             stdout_tty?: false,
             controlling_tty?: false
           } = %Probe{}

    refute function_exported?(Probe, :detect, 0)
    refute function_exported?(Probe, :probe, 0)
  end
end
