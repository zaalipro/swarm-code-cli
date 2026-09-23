defmodule SwarmCode.Domain.LLM.ToolArgsTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.LLM.ToolArgs

  test "a JSON object decodes to a map" do
    assert {:ok, %{"path" => "a.ex", "content" => "x"}} =
             ToolArgs.decode(~s({"path":"a.ex","content":"x"}))
  end

  test "no arguments is not an error" do
    assert {:ok, %{}} = ToolArgs.decode("")
    assert {:ok, %{}} = ToolArgs.decode("{}")
  end

  test "truncated JSON reports why instead of pretending there were no arguments" do
    # This is the shape that produced five identical `missing required argument
    # "path" for write_file` failures in one swarm run (2026-08-23): a large
    # `content` value whose JSON never closed.
    assert {:error, reason} = ToolArgs.decode(~s({"path":"a.ex","content":"unterminated))
    assert reason != ""
    refute reason =~ "missing required argument"
  end

  test "unescaped control characters inside a string are reported" do
    assert {:error, _reason} = ToolArgs.decode(~s({"content":"line one\nline two"}))
  end

  test "a JSON value that is not an object is an error, not an empty map" do
    assert {:error, "expected a JSON object, got an array"} = ToolArgs.decode("[1,2]")
    assert {:error, "expected a JSON object, got a string"} = ToolArgs.decode(~s("text"))
    assert {:error, "expected a JSON object, got a number"} = ToolArgs.decode("12")
    assert {:error, "expected a JSON object, got null"} = ToolArgs.decode("null")
    assert {:error, "expected a JSON object, got a boolean"} = ToolArgs.decode("true")
  end

  test "a non-binary argument is an error" do
    assert {:error, _reason} = ToolArgs.decode(nil)
    assert {:error, _reason} = ToolArgs.decode(%{"path" => "a"})
  end

  test "the reason is bounded so it cannot flood the model's context" do
    assert {:error, reason} = ToolArgs.decode("{" <> String.duplicate("\"a\":", 5_000))
    assert byte_size(reason) <= 201
  end
end
