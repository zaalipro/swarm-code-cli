defmodule SwarmCodeCLI.Release.ReadPromptTest do
  @moduledoc """
  cli020 B1 (bugs-2, onboarding-7): `-p -` reads a UTF-8 prompt from stdin,
  says what is wrong with one it cannot take, and a `-p PROMPT` with piped
  stdin sends the stdin after the prompt.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Release

  defp device(content), do: content |> StringIO.open() |> elem(1)
  defp options(prompt), do: %{mode: :prompt, prompt: prompt, format: :text}

  test "a non-ASCII prompt on stdin is accepted" do
    assert {:ok, %{prompt: "héllo ✓"}} = Release.read_prompt(options("-"), device("héllo ✓"), %{})
  end

  test "an empty stdin, invalid UTF-8 and an oversized prompt each say what is wrong" do
    assert {:error, "the prompt on stdin is empty."} =
             Release.read_prompt(options("-"), device(""), %{})

    assert {:error, "the prompt on stdin is empty."} =
             Release.read_prompt(options("-"), device("  \n"), %{})

    assert {:error, "the prompt on stdin is not UTF-8."} =
             Release.read_prompt(options("-"), device(<<"ab", 0xFF, 0xFE>>), %{})

    big = String.duplicate("é", 140_000)

    assert {:error, "the prompt on stdin is over 256 KiB."} =
             Release.read_prompt(options("-"), device(big), %{})
  end

  test "a prompt with piped stdin appends the stdin block" do
    env = %{"SWARM_STDIN_PIPED" => "1"}

    assert {:ok, %{prompt: prompt}} =
             Release.read_prompt(options("review this"), device("diff --git a b\n+ü\n"), env)

    assert prompt == "review this\n\n<stdin>\ndiff --git a b\n+ü\n\n</stdin>"
  end

  test "piped stdin is read only when the launcher saw a pipe, and an empty one changes nothing" do
    assert {:ok, %{prompt: "hi"}} = Release.read_prompt(options("hi"), device("ignored"), %{})

    assert {:ok, %{prompt: "hi"}} =
             Release.read_prompt(options("hi"), device(""), %{"SWARM_STDIN_PIPED" => "1"})
  end

  test "the prompt and its piped stdin are bounded together" do
    env = %{"SWARM_STDIN_PIPED" => "1"}

    assert {:error, "the prompt and its piped stdin are over 256 KiB."} =
             Release.read_prompt(options("look"), device(String.duplicate("a", 262_140)), env)

    assert {:error, "the prompt on stdin is not UTF-8."} =
             Release.read_prompt(options("look"), device(<<0xFF>>), env)
  end
end
