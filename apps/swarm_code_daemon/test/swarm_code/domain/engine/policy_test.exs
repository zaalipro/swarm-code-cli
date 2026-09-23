defmodule SwarmCode.Domain.Engine.PolicyTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Engine.Policy

  test "read is always allowed" do
    for mode <- ["read_only", "auto", "full_access"] do
      assert Policy.decide(mode, :read) == :allow
    end
  end

  test "read_only blocks writes and commands" do
    assert Policy.decide("read_only", :write) ==
             {:deny, "blocked by Read-only approval mode"}

    assert Policy.decide("read_only", :execute) ==
             {:deny, "blocked by Read-only approval mode"}
  end

  test "auto allows writes and asks for commands" do
    assert Policy.decide("auto", :write) == :allow
    # spec 68 T6: auto/execute is unconditionally :ask (always-allow lives in RunServer).
    assert Policy.decide("auto", :execute) == :ask
  end

  test "full_access allows everything" do
    assert Policy.decide("full_access", :write) == :allow
    assert Policy.decide("full_access", :execute) == :allow
  end

  # spec 66 T4: the class of the command is the fourth argument.
  # spec 68 T6: `always` parameter removed; the arity dropped by one.
  test "a safe command runs unasked, a dangerous one always asks" do
    assert Policy.decide("auto", :execute, :safe) == :allow
    assert Policy.decide("full_access", :execute, :safe) == :allow
    assert Policy.decide("auto", :execute, :dangerous) == :ask
    assert Policy.decide("full_access", :execute, :dangerous) == :ask

    # Read-only still denies every command, whatever its class.
    assert Policy.decide("read_only", :execute, :safe) ==
             {:deny, "blocked by Read-only approval mode"}

    # And a missing class behaves exactly as before the task.
    assert Policy.decide("auto", :execute) == :ask
  end
end
