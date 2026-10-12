defmodule SwarmCodeCLI.Release.ConfigOutputTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Release.ConfigOutput

  test "external cells repair UTF-8 and render controls without row injection" do
    for input <- ["\e]52;c;payload\a", "\e[2J\a", "a\r\nb", <<255, 9, 120>>, "لا\tx"] do
      cell = ConfigOutput.cell(input)
      assert String.valid?(cell)
      for byte <- ["\e", "\a", "\r", "\n"], do: refute(cell =~ byte)
    end

    assert ConfigOutput.cell("a\nb") == "a\\nb"
    assert ConfigOutput.cell("plain 日本語") == "plain 日本語"
  end

  test "input and escaped overflow never fall back to raw values" do
    assert ConfigOutput.cell(String.duplicate("a", 65_537)) == "[value exceeds display limit]"
    assert ConfigOutput.cell(String.duplicate(<<0>>, 65_536)) == "[value exceeds display limit]"
    assert ConfigOutput.cell(String.duplicate("a", 65_536)) == String.duplicate("a", 65_536)
  end
end
