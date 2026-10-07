defmodule SwarmCode.Domain.Engine.Policy do
  @moduledoc "Approval decisions."

  # spec 66 T4: the fourth argument is `SwarmCode.Domain.Tools.CommandSafety.classify/1`
  # for a `run_command` and `:normal` for everything else. A `:dangerous` command
  # is always asked about (an "Always allow" of the `:execute` class cannot cover
  # it), and a `:safe` one — `ls`, `git status`, `cat x | grep y` — stops
  # interrupting the user in Auto and Full access.
  #
  # pass 72 F1 (CLI 0.2.0 decision 3): read-only asks before every write and
  # every command; a `:safe` command asks too. It used to refuse both outright,
  # which left a new (untrusted, read-only) project with no path forward but
  # the mode switch. The RunServer never remembers a read-only answer
  # (`request_approval/5` stores the mode with the approval).
  #
  # spec 68 T6: removed the vestigial `always` MapSet parameter — the real
  # always-allow check lives in RunServer.handle_call(:request_approval) before
  # Policy is ever called. Operation.run always passed MapSet.new().
  def decide(mode, permission, safety \\ :normal)

  def decide(_mode, :execute, :dangerous), do: :ask

  def decide(mode, :execute, :safe) when mode in ["auto", "full_access"], do: :allow

  def decide(_mode, :read, _safety), do: :allow

  # spec 74 BUGS-47: a fetch that reaches loopback, a private range or a
  # link-local address (or a dotless intranet name) asks in Read-only and
  # Auto. It is not `:read`: a page on `localhost` or `10.x` is the user's
  # own network, not the web. Full access allows it below.
  def decide(mode, :private_network, _safety) when mode in ["read_only", "auto"], do: :ask

  def decide("read_only", permission, _safety) when permission in [:write, :execute],
    do: :ask

  def decide("auto", :write, _safety), do: :allow

  # spec 68 T6: unconditionally :ask — the always-allow gate is in RunServer.
  def decide("auto", :execute, _safety), do: :ask

  def decide("full_access", _permission, _safety), do: :allow

  def decide(_mode, _permission, _safety), do: :ask
end
