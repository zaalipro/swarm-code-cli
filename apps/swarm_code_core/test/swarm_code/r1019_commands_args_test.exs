defmodule SwarmCode.R1019CommandsArgsTest do
  @moduledoc """
  pass 77 C-FEAT-8: a custom command's `$1`-`$9` take the typed words one by one,
  like the desktop's `Commands.expand/2` (D3-3); one pass fills every marker.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Commands

  defp parse(body, input), do: Commands.parse(input, custom: [%{name: "ship", body: body}])

  test "positional words fill $1..$9 and $ARGUMENTS keeps the whole text" do
    assert {:ok, %{prompt: "to prod by Friday (to prod Friday)"}} =
             parse("$1 $2 by $3 ($ARGUMENTS)", "/ship to prod Friday")
  end

  test "quotes group a phrase and a missing word is empty" do
    assert {:ok, %{prompt: "fix: the login bug|"}} =
             parse("$1: $2|$3", ~s(/ship fix "the login bug"))
  end

  test "$10 is not positional and typed markers are not expanded again" do
    assert {:ok, %{prompt: "$1 $10"}} = parse("$1 $10", "/ship $1")
  end

  test "a positional-only body shows the args hint" do
    [entry] =
      Commands.catalogue("/ship", custom: [%{name: "ship", body: "deploy $1"}])
      |> Enum.filter(&(&1.name == "ship"))

    assert entry.args == "<args>"
  end
end
