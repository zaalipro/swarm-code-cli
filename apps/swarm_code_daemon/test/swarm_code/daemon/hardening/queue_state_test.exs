defmodule SwarmCode.Daemon.Hardening.QueueStateTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Daemon.Service.QueueState, as: Q

  test "owners, monitors and replacement generations are independent" do
    {q, a} = Q.activate(Q.new(), "a")
    {q, b} = Q.activate(q, "b")
    assert a < b
    assert {^q, ^a} = Q.activate(q, "a")
    ra = make_ref()
    rb = make_ref()
    q = q |> Q.put_monitor("a", ra, self()) |> Q.put_monitor("b", rb, self())
    {q, {"a", ^a}} = Q.pop_monitor(q, ra)
    assert Q.entry(q, "a").monitors == %{}
    assert Q.entry(q, "b").monitors == %{rb => self()}
    assert {^q, :stale} = Q.pop_monitor(q, ra)
    q = Q.remove(q, "a")
    {q, replacement} = Q.activate(q, "a")
    assert replacement > b
    assert {^q, :stale} = Q.pop_monitor(q, ra)
  end

  test "eight retries and timers belong to each owner; reset and remove are pure" do
    {q, _} = Q.activate(Q.new(), "a")
    {q, _} = Q.activate(q, "b")
    timer = make_ref()
    q = Q.put_timer(q, "a", timer)

    q =
      Enum.reduce(1..8, q, fn _, q ->
        {q, :retry} = Q.retry(q, "a")
        q
      end)

    assert {^q, :exhausted} = Q.retry(q, "a")
    assert Q.entry(q, "a").timer == timer
    assert Q.entry(q, "b").retries == 0
    q = Q.reset(q, "a")
    assert Q.entry(q, "a").retries == 0
    assert Q.entry(q, "a").timer == nil
    assert Q.entry(Q.remove(q, "a"), "a") == nil
  end

  test "a held prompt survives an exhausted retry and is released once stored again" do
    {q, _} = Q.activate(Q.new(), "a")
    assert Q.held(Q.entry(q, "a")) == []
    assert Q.held(nil) == []
    q = q |> Q.hold("a", "first") |> Q.hold("a", "second")
    assert Q.held(Q.entry(q, "a")) == ["first", "second"]

    q =
      Enum.reduce(1..8, q, fn _, q ->
        {q, :retry} = Q.retry(q, "a")
        q
      end)

    assert {q, :exhausted} = Q.retry(q, "a")
    assert Q.held(Q.entry(q, "a")) == ["first", "second"]
    assert {q, :first} = Q.warn(q, "a")
    assert {q, :again} = Q.warn(q, "a")

    q = Q.release(q, "a")
    assert Q.held(Q.entry(q, "a")) == []
    assert {_, :first} = Q.warn(q, "a")
  end
end
