defmodule SwarmCode.Protocol.R1019CapabilityTableTest do
  @moduledoc """
  pass 77 C-ARCH-9: one capability table in core serves the daemon's
  connection and the terminal client. The golden tables below are the two
  hand-written copies it replaced (the connection's `case` on the operation
  and the client's `request_capability/1` clauses), copied as they stood.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.ServiceRequest

  # The connection's `capability?/2`, by operation.
  @server %{
    feature_query: :query,
    agent_detail: :query,
    feature_command: :feature_command,
    settings_query: :settings,
    settings_command: :settings,
    question_answer: :question_answer,
    queue_resume: :queue,
    queue_edit: :queue,
    run_retry: :run_retry,
    history_search: :history,
    home_overview: :home,
    conversation_search: :home,
    rewind_apply: :rewind,
    rewind_turns: :rewind,
    shell_stop: :shell,
    shell_run: :shell,
    attachment_attach: :attachment,
    attachment_slot: :attachment,
    query: :query,
    detail: :detail,
    watch: :watch,
    conversation_open: :conversation_open,
    conversation_list: :conversation_list,
    conversation_new: :conversation_new,
    mark_seen: :mark_seen,
    project_update: :project_update,
    ack: :watch,
    unwatch: :watch,
    resync: :watch,
    dispatch_send: :dispatch_send,
    run_steer: :run_steer,
    approval_resolve: :approval_resolve,
    cancel: nil
  }

  # The client's `request_capability/1`, by wire op (and action). It never
  # asked about watch, ack, unwatch, resync or cancel: those are not requests.
  @client [
    {"query", nil, :query},
    {"feature.query", nil, :query},
    {"agent.detail", nil, :query},
    {"feature.command", nil, :feature_command},
    {"question.answer", nil, :question_answer},
    {"detail", nil, :detail},
    {"dispatch", nil, :dispatch_send},
    {"run.control", "pause", :run_pause},
    {"run.control", "continue", :run_continue},
    {"run.control", "stop", :run_stop},
    {"run.steer", nil, :run_steer},
    {"approval.resolve", nil, :approval_resolve},
    {"conversation.open", nil, :conversation_open},
    {"conversation.list", nil, :conversation_list},
    {"conversation.new", nil, :conversation_new},
    {"home.overview", nil, :home},
    {"conversation.search", nil, :home},
    {"mark_seen", nil, :mark_seen},
    {"project.update", nil, :project_update},
    {"settings.query", nil, :settings},
    {"settings.command", nil, :settings},
    {"queue.resume", nil, :queue},
    {"queue.edit", nil, :queue},
    {"run.retry", nil, :run_retry},
    {"attachment.slot", nil, :attachment},
    {"attachment.attach_slot", nil, :attachment},
    {"shell.run", nil, :shell},
    {"shell.stop", nil, :shell},
    {"rewind.turns", nil, :rewind},
    {"rewind.apply", nil, :rewind},
    {"history.search", nil, :history}
  ]

  test "every operation needs what the connection used to require" do
    for {operation, capability} <- @server do
      assert ServiceRequest.capability(operation, %{}) == capability, inspect(operation)
    end
  end

  test "run.control depends on its action, and an unknown action needs nothing" do
    for {action, capability} <- [pause: :run_pause, continue: :run_continue, stop: :run_stop] do
      assert ServiceRequest.capability(:run_control, %{"action" => Atom.to_string(action)}) ==
               capability
    end

    assert ServiceRequest.capability(:run_control, %{"action" => "explode"}) == nil
    assert ServiceRequest.capability(:run_control, %{}) == nil
  end

  test "the wire form answers what the client used to" do
    for {op, action, capability} <- @client do
      wire = if action, do: %{"op" => op, "action" => action}, else: %{"op" => op}
      assert ServiceRequest.capability_for_wire(wire) == capability, inspect(wire)
    end
  end

  test "the wire form agrees with the connection for every op both sides knew" do
    for {op, action, capability} <- @client do
      operation =
        if op == "run.control",
          do: :run_control,
          else: Enum.find(Map.keys(@server), &(wire_name(&1) == op))

      params = if action, do: %{"action" => action}, else: %{}
      assert ServiceRequest.capability(operation, params) == capability, op
    end
  end

  test "an unknown op, a missing op and a non-map need nothing" do
    assert ServiceRequest.capability_for_wire(%{"op" => "no.such"}) == nil
    assert ServiceRequest.capability_for_wire(%{"op" => "cancel"}) == nil
    assert ServiceRequest.capability_for_wire(%{}) == nil
    assert ServiceRequest.capability_for_wire(nil) == nil
    assert ServiceRequest.capability_for_wire(%{"op" => 7}) == nil
  end

  defp wire_name(:feature_query), do: "feature.query"
  defp wire_name(:agent_detail), do: "agent.detail"
  defp wire_name(:feature_command), do: "feature.command"
  defp wire_name(:settings_query), do: "settings.query"
  defp wire_name(:settings_command), do: "settings.command"
  defp wire_name(:question_answer), do: "question.answer"
  defp wire_name(:queue_resume), do: "queue.resume"
  defp wire_name(:queue_edit), do: "queue.edit"
  defp wire_name(:run_retry), do: "run.retry"
  defp wire_name(:history_search), do: "history.search"
  defp wire_name(:home_overview), do: "home.overview"
  defp wire_name(:conversation_search), do: "conversation.search"
  defp wire_name(:rewind_apply), do: "rewind.apply"
  defp wire_name(:rewind_turns), do: "rewind.turns"
  defp wire_name(:shell_stop), do: "shell.stop"
  defp wire_name(:shell_run), do: "shell.run"
  defp wire_name(:attachment_attach), do: "attachment.attach_slot"
  defp wire_name(:attachment_slot), do: "attachment.slot"
  defp wire_name(:conversation_open), do: "conversation.open"
  defp wire_name(:conversation_list), do: "conversation.list"
  defp wire_name(:conversation_new), do: "conversation.new"
  defp wire_name(:project_update), do: "project.update"
  defp wire_name(:dispatch_send), do: "dispatch"
  defp wire_name(:run_steer), do: "run.steer"
  defp wire_name(:approval_resolve), do: "approval.resolve"
  defp wire_name(other), do: Atom.to_string(other)
end
