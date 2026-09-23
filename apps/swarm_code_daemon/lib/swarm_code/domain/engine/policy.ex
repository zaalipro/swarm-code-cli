defmodule SwarmCode.Domain.Engine.Policy do
  @moduledoc "Approval decisions."

  # spec 66 T4: the fourth argument is `SwarmCode.Domain.Tools.CommandSafety.classify/1`
  # for a `run_command` and `:normal` for everything else. Three clauses come
  # before the old ones and nothing below them changed: read-only still denies
  # every command whatever its class, a `:dangerous` one is always asked about
  # (an "Always allow" of the `:execute` class cannot cover it), and a `:safe`
  # one — `ls`, `git status`, `cat x | grep y` — stops interrupting the user.
  #
  # spec 68 T6: removed the vestigial `always` MapSet parameter — the real
  # always-allow check lives in RunServer.handle_call(:request_approval) before
  # Policy is ever called. Operation.run always passed MapSet.new().
  def decide(mode, permission, safety \\ :normal)

  def decide("read_only", :execute, _safety),
    do: {:deny, "blocked by Read-only approval mode"}

  def decide(_mode, :execute, :dangerous), do: :ask

  def decide(mode, :execute, :safe) when mode in ["auto", "full_access"], do: :allow

  def decide(_mode, :read, _safety), do: :allow

  def decide("read_only", permission, _safety) when permission in [:write, :execute],
    do: {:deny, "blocked by Read-only approval mode"}

  def decide("auto", :write, _safety), do: :allow

  # spec 68 T6: unconditionally :ask — the always-allow gate is in RunServer.
  def decide("auto", :execute, _safety), do: :ask

  def decide("full_access", _permission, _safety), do: :allow

  def decide(_mode, _permission, _safety), do: :ask
end
