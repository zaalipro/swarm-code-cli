defmodule SwarmCode.Domain.Engine.PolicyTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Engine.Policy

  test "read is always allowed" do
    for mode <- ["read_only", "auto", "full_access"] do
      assert Policy.decide(mode, :read) == :allow
    end
  end

  # pass 72 F1 (CLI 0.2.0 decision 3): read-only asks before every write and
  # every command, whatever its class, instead of refusing.
  test "read_only asks for writes and every command class" do
    assert Policy.decide("read_only", :write) == :ask
    assert Policy.decide("read_only", :execute) == :ask

    for safety <- [:safe, :normal, :dangerous] do
      assert Policy.decide("read_only", :execute, safety) == :ask
      assert Policy.decide("read_only", :write, safety) == :ask
    end

    assert Policy.decide("read_only", :read) == :allow
    assert Policy.decide("read_only", :private_network) == :ask
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

    # pass 72 F1: read-only asks for every command, a safe one included.
    assert Policy.decide("read_only", :execute, :safe) == :ask

    # And a missing class behaves exactly as before the task.
    assert Policy.decide("auto", :execute) == :ask
  end
end
