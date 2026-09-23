defmodule SwarmCode.Domain.Tools.Polish53ToolsTest do
  # spec 60 T6: `Tools.truncate/1` caps error text like a result; T16: the process-tree
  # walk goes past the old depth cap.
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Tools

  # spec 61 T5 replaced the silent "…[truncated]" cut with a trailer that says
  # how much was dropped; the cap itself is still spec 60 T6's.
  test "truncate/1 caps error text too (spec 60 T6)" do
    {:error, out} = Tools.truncate({:error, String.duplicate("e", 300_000)})
    assert out =~ Tools.truncation_marker()
    assert String.length(out) < 300_000
    assert Tools.truncate({:error, "short"}) == {:error, "short"}

    {:ok, ok_out} = Tools.truncate({:ok, String.duplicate("o", 300_000)})
    assert ok_out =~ Tools.truncation_marker()
    assert Tools.truncate({:ok, "short"}) == {:ok, "short"}
  end

  # spec 60 T16: the walk used to stop at depth 8; a 12-link chain now comes back whole.
  test "tree_of/2 walks past the old depth cap (spec 60 T16)" do
    map = Map.new(1..12, &{&1, [&1 + 1]})
    assert length(SwarmCode.Domain.OSProcess.tree_of([1], map)) == 13
  end
end
