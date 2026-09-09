defmodule SwarmCode.Domain.Engine.PolicyTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Engine.Policy

  @empty MapSet.new()
  @always MapSet.new([:execute])

  test "read is always allowed" do
    for mode <- ["read_only", "auto", "full_access"] do
      assert Policy.decide(mode, :read, @empty) == :allow
    end
  end

  test "read_only blocks writes and commands" do
    assert Policy.decide("read_only", :write, @empty) ==
             {:deny, "blocked by Read-only approval mode"}

    assert Policy.decide("read_only", :execute, @always) ==
             {:deny, "blocked by Read-only approval mode"}
  end

  test "auto allows writes and asks for commands" do
    assert Policy.decide("auto", :write, @empty) == :allow
    assert Policy.decide("auto", :execute, @empty) == :ask
    assert Policy.decide("auto", :execute, @always) == :allow
  end

  test "full_access allows everything" do
    assert Policy.decide("full_access", :write, @empty) == :allow
    assert Policy.decide("full_access", :execute, @empty) == :allow
  end
end
