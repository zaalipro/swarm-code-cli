defmodule SwarmCodeCLI.UI.DataSource.Daemon.Codec do
  @moduledoc "Pure translation of typed requests, replies and watch events; owns no transport or credit."
  require Logger
  alias SwarmCode.Protocol.{Frame, Message, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delta, Delivery, DTO, Request, Watch}

  @responses %{
    "outcome" => {:outcome, DTO.Outcome},
    "shell_snapshot" => {:shell_snapshot, DTO.ShellSnapshot},
    "workspace_snapshot" => {:workspace_snapshot, DTO.WorkspaceSnapshot},
    "transcript_window" => {:transcript_window, DTO.TranscriptWindow},
    "activity_snapshot" => {:activity_snapshot, DTO.ActivitySnapshot},
    "run_detail_snapshot" => {:run_detail_snapshot, DTO.RunDetailSnapshot},
    "pending_interactions" => {:pending_interactions, DTO.PendingInteractionWindow},
    "detail_window" => {:detail_window, DTO.DetailWindow},
    "library_snapshot" => {:library_snapshot, DTO.LibrarySnapshot},
    "conversation_list" => {:conversation_list, DTO.ConversationList},
    "agent_detail" => {:agent_detail, DTO.AgentDetail}
  }

  @watch_bodies %{
    shell: "shell_snapshot",
    workspace: "workspace_snapshot",
    activity: "activity_snapshot",
    inspector: "run_detail_snapshot"
  }

  # Keys a daemon may omit on the v1 wire: fields added after the body was
  # frozen, filled from each DTO's wire defaults. Legacy fixture-only defaults
  # (`allowed_actions`, `created_sequence`, ...) stay mandatory on the wire.
  @optional_wire_keys %{
    DTO.WorkspaceSnapshot => [
      :mode,
      :chat_model,
      :swarm_model,
      :effort,
      :swarm_effort,
      :changes,
      :verdicts,
      :agents,
      :project,
      :models,
      :approval_mode,
      :trusted,
      :chat_provider,
      :context_used,
      :context_window,
      :cost_usd,
      :title,
      :background,
      :queued
    ],
    DTO.WorkspaceMetadata => [
      :project,
      :models,
      :approval_mode,
      :trusted,
      :chat_provider,
      :context_used,
      :context_window,
      :cost_usd,
      :title,
      :queued
    ],
    DTO.ShellSnapshot => [:rate_limits],
    DTO.Approval => [
      :command,
      :cwd,
      :reason,
      :command_family,
      :classification,
      :agent_id,
      :agent_name,
      :requested_at,
      :allowed_decisions
    ],
    DTO.LibraryItem => [:matches],
    DTO.TranscriptItem => [:kind, :tool, :agent_id, :tokens_in, :tokens_out, :at],
    DTO.AgentSummary => [
      :name,
      :role,
      :title,
      :step,
      :progress,
      :tokens_in,
      :tokens_out,
      :cost_usd,
      :started_at,
      :finished_at,
      :parent_id,
      :depth,
      :changes_stat,
      :error,
      :model,
      :provider_name,
      :stop_reason,
      :error_kind,
      :stop_label,
      :retry_at,
      # pass72 S: the side panel's agent facts.
      :panel_state,
      :now,
      :lane,
      :lane_at,
      :lane_now,
      :finding,
      :finding_refs,
      :files_changed,
      :elapsed_ms,
      :tokens
    ],
    DTO.RunSummary => [
      :tokens_in,
      :tokens_out,
      :cost_usd,
      :model,
      :agents_total,
      :agents_running,
      :needs,
      :changes,
      :started_at,
      :finished_at,
      :consensus,
      :error,
      :stop_reason,
      :error_kind,
      :stop_label,
      :provider_name,
      :retry_at,
      # pass72 S: the side panel's run facts.
      :needs_you,
      :reported,
      :total,
      :phases,
      :phase,
      :goal_iteration,
      :goal_iterations,
      :goal_status,
      :round,
      :rounds,
      :verdict
    ],
    DTO.ToolCall => [
      :title,
      :detail,
      :status,
      :started_at,
      :finished_at,
      :duration_ms,
      :result_bytes,
      :files,
      :added,
      :removed,
      :diff_ref,
      :exit_code,
      :background,
      :hunk,
      :diff_lines
    ],
    DTO.Change => [
      :agent_id,
      :restorable,
      :at,
      :op_id,
      :file_state,
      :added,
      :removed,
      :diff_ref
    ],
    DTO.Verdict => [:round, :status, :checks, :summary],
    DTO.VerdictCheck => [:ok, :note],
    # pass72 G19: `tool`, the approval's tool (absent from older bodies).
    DTO.NeedsYou => [:agent_id, :node_id, :agent_name, :reason, :requested_at, :tool],
    DTO.Phase => [:agent_count, :live, :done]
  }

  def watch_request(watch, wire_id, nonce, timeout_ms) do
    with {:ok, watch} <- Watch.validate(watch),
         body = watch_body(watch, timeout_ms),
         {:ok, _} <- ServiceRequest.decode(body, watch.scope),
         message = %Message{
           version: 1,
           type: :request,
           request_id: wire_id,
           nonce: nonce,
           scope: watch.scope,
           sequence: nil,
           occurred_at: nil,
           body: body
         },
         {:ok, _} <- Frame.encode(message) do
      {:ok, message}
    else
      _ -> invalid()
    end
  end

  @doc "Validate event correlation and content. The adapter owns sequence/epoch transitions and ACKs."
  def event(message, watch, nonce) do
    with {:watch, {:ok, watch}} <- {:watch, Watch.validate(watch)},
         {:watch_body, {:ok, _}} <-
           {:watch_body, ServiceRequest.decode(watch_body(watch, 1), watch.scope)},
         {:frame, {:ok, _}} <- {:frame, Frame.encode(message)},
         {:envelope, true} <-
           {:envelope,
            message.request_id == nil and message.nonce == nonce and
              message.scope == watch.scope},
         {:sequence, true} <- {:sequence, is_integer(message.sequence)},
         {:watch_ref, true} <- {:watch_ref, message.body["watch_ref"] == watch.watch_ref} do
      event_body(message, watch)
    else
      # pass72 F: which envelope check failed, never the payload.
      {step, _} ->
        Logger.warning("SwarmCode: event rejected: #{step}")
        invalid()
    end
  end

  defp wire_slot(%{slot: :workspace, scope: %{kind: :run}}), do: :inspector
  defp wire_slot(%{slot: slot}), do: slot

  defp watch_body(watch, timeout_ms),
    do: %{
      "op" => "watch",
      "watch_ref" => watch.watch_ref,
      "slot" => Atom.to_string(wire_slot(watch)),
      "page_size" => watch.page_size,
      "byte_limit" => watch.byte_limit,
      "timeout_ms" => timeout_ms
    }

  defp event_body(
         %Message{
           type: :event,
           body:
             %{
               "op" => "watch_ready",
               "revision" => revision,
               "body_kind" => kind,
               "value" => value
             } = body
         } = message,
         watch
       )
       when map_size(body) == 5 do
    with true <- @watch_bodies[wire_slot(watch)] == kind,
         {_expected, module} <- @responses[kind],
         {:ok, dto} <- module.decode(value),
         true <- exact_wire_shape?(dto, value),
         {:ok, ^dto} <- restore_identities(dto, nil, nil),
         true <- scoped_body?(watch.scope, dto),
         true <- watermark_matches?(dto, message.sequence),
         true <- body_revision?(dto, revision),
         {:ok, bytes} <- Jason.encode(value),
         true <- byte_size(bytes) <= watch.byte_limit,
         true <- page_sizes?(dto, watch.page_size) do
      watch_delivery(watch, :watch_ready, dto, revision, nil)
    else
      _ ->
        # pass72 F: a rejected snapshot closes the session; the log names the
        # check it failed (never the payload), so the close can be fixed.
        Logger.warning(
          "SwarmCode: watch_ready rejected: " <>
            rejected_step(message, watch, kind, value, revision)
        )

        invalid()
    end
  end

  defp event_body(
         %Message{type: :event, body: %{"op" => "delta", "value" => value} = body} = message,
         watch
       )
       when map_size(body) == 3 do
    with {:ok, delta} <- Delta.decode(value),
         true <- exact_wire_shape?(delta, value),
         true <- delta.sequence == message.sequence,
         true <- body_revision?(delta.body, delta.revision),
         true <- scoped_delta?(watch.scope, delta),
         true <- delta.kind != :snapshot_required do
      watch_delivery(watch, :delta, delta, delta.revision, delta.sequence)
    else
      _ -> invalid()
    end
  end

  defp event_body(
         %Message{
           type: :snapshot_required,
           body: %{"op" => "snapshot_required", "reason" => reason} = body
         },
         watch
       )
       when map_size(body) == 3 and reason in ["overflow", "gap", "epoch_changed"],
       do: watch_delivery(watch, :resyncing, nil, nil, nil)

  defp event_body(_, _), do: invalid()

  defp watch_delivery(watch, kind, body, revision, sequence) do
    case Delivery.validate(%Delivery{
           kind: kind,
           watch_ref: watch.watch_ref,
           request_id: nil,
           scope: watch.scope,
           generation: watch.generation,
           revision: revision,
           sequence: sequence,
           body: body
         }) do
      {:ok, delivery} -> {:ok, delivery}
      _ -> invalid()
    end
  end

  defp body_revision?(%{revision: revision}, expected), do: revision == expected
  defp body_revision?(_, _), do: true

  defp watermark_matches?(%{__struct__: _} = dto, sequence) do
    Map.get(dto, :through_sequence, sequence) == sequence and
      Enum.all?(Map.from_struct(dto), fn {_, value} -> watermark_matches?(value, sequence) end)
  end

  defp watermark_matches?(values, sequence) when is_list(values),
    do: Enum.all?(values, &watermark_matches?(&1, sequence))

  defp watermark_matches?(_, _), do: true

  defp page_sizes?(%{__struct__: _} = dto, limit) do
    Enum.all?(Map.from_struct(dto), fn {key, value} ->
      (key not in [:runs, :items, :agents, :interactions] or length(value) <= limit) and
        page_sizes?(value, limit)
    end)
  end

  defp page_sizes?(values, limit) when is_list(values),
    do: Enum.all?(values, &page_sizes?(&1, limit))

  defp page_sizes?(_, _), do: true

  defp scoped_delta?(_, %Delta{kind: kind})
       when kind in [:counts_update, :connection, :toast, :rate_limit],
       do: true

  defp scoped_delta?(%{kind: :global}, %Delta{kind: :workspace_metadata}), do: false
  defp scoped_delta?(%{kind: :project}, %Delta{kind: :workspace_metadata}), do: false
  defp scoped_delta?(%{kind: kind}, _) when kind in [:global, :project], do: true
  defp scoped_delta?(%{kind: :conversation, id: id}, delta), do: delta.conversation_id == id
  defp scoped_delta?(%{kind: :run, id: id}, delta), do: delta.run_id == id

  def request(request, wire_id, nonce, now) do
    with {:ok, request} <- Request.validate(request),
         true <- is_integer(now),
         :ok <- not_expired(request.deadline, now),
         {:ok, body} <- request_body(request.kind),
         body =
           body
           |> wire_request_slot(request.scope)
           |> Map.put("timeout_ms", min(request.deadline - now, 600_000)),
         {:ok, _} <- ServiceRequest.decode(body, request.scope),
         message = %Message{
           version: 1,
           type: :request,
           request_id: wire_id,
           nonce: nonce,
           scope: request.scope,
           sequence: nil,
           occurred_at: nil,
           body: body
         },
         {:ok, _} <- Frame.encode(message) do
      {:ok, message}
    else
      {:error, %AdmissionError{}} = error -> error
      _ -> invalid()
    end
  end

  def response(message, request, wire_id, nonce) do
    with {:ok, request} <- Request.validate(request),
         {:ok, _} <- Frame.encode(message),
         true <- message.request_id == wire_id and message.nonce == nonce,
         true <- message.scope == request.scope do
      response_body(message, request)
    else
      _ -> invalid()
    end
  end

  # Run destinations occupy the UI workspace, but the service exposes their
  # snapshots and transcript pages through the inspector slot.
  defp wire_request_slot(%{"op" => "query", "slot" => slot} = body, %{kind: :run})
       when slot in ["workspace", "transcript"],
       do: Map.put(body, "slot", "inspector")

  defp wire_request_slot(body, _), do: body

  defp request_body({:query, slot, cursor, direction, size, bytes}) do
    {:ok,
     %{
       "op" => "query",
       "slot" => Atom.to_string(slot),
       "cursor" => cursor,
       "direction" => Atom.to_string(direction),
       "page_size" => size,
       "byte_limit" => bytes
     }}
  end

  defp request_body({:query_detail, ref, offset, bytes}),
    do: {:ok, %{"op" => "detail", "detail_ref" => ref, "offset" => offset, "bytes" => bytes}}

  defp request_body({:feature_query, feature, id, cursor, size, bytes}),
    do:
      {:ok,
       %{
         "op" => "feature.query",
         "feature" => Atom.to_string(feature),
         "id" => id,
         "cursor" => cursor,
         "page_size" => size,
         "byte_limit" => bytes
       }}

  defp request_body({:resync_watch, ref}), do: {:ok, %{"op" => "resync", "watch_ref" => ref}}

  defp request_body({:agent_detail, run_id, node_id}),
    do: {:ok, %{"op" => "agent.detail", "run_id" => run_id, "node_id" => node_id}}

  defp request_body({:conversation_list, cursor, size, bytes}),
    do:
      {:ok,
       %{
         "op" => "conversation.list",
         "cursor" => cursor,
         "page_size" => size,
         "byte_limit" => bytes
       }}

  defp request_body({:conversation_new}), do: {:ok, %{"op" => "conversation.new"}}

  defp request_body({:conversation_open, id}),
    do: {:ok, %{"op" => "conversation.open", "conversation_id" => id}}

  defp request_body({:project_update, mode, trusted}),
    do:
      {:ok,
       %{
         "op" => "project.update",
         "approval_mode" => if(mode, do: Atom.to_string(mode)),
         "trusted" => trusted
       }}

  defp request_body({:mark_seen, kind, id, revision}),
    do:
      {:ok,
       %{
         "op" => "mark_seen",
         "kind" => Atom.to_string(kind),
         "id" => id,
         "revision" => revision
       }}

  defp request_body({:feature_command, feature, action, id, attrs}),
    do:
      {:ok,
       %{
         "op" => "feature.command",
         "feature" => Atom.to_string(feature),
         "action" => Atom.to_string(action),
         "id" => id,
         "attributes" => attrs
       }}

  defp request_body({:answer_question, run, node, interaction, revision, answers})
       when is_list(answers),
       do:
         request_body(
           {:answer_question, run, node, interaction, revision,
            %{option_ids: answers, custom_text: ""}}
         )

  defp request_body(
         {:answer_question, run, node, interaction, revision,
          %{option_ids: answers, custom_text: custom}}
       ),
       do:
         {:ok,
          %{
            "op" => "question.answer",
            "run_id" => run,
            "node_id" => node,
            "interaction_id" => interaction,
            "expected_revision" => revision,
            "answers" => answers,
            "custom_text" => custom
          }}

  defp request_body({:dispatch, action, text, :main, attachments})
       when action in [:send, :queue] and is_list(attachments),
       do:
         {:ok,
          %{
            "op" => "dispatch",
            "action" => Atom.to_string(action),
            "text" => text,
            "target" => %{"kind" => "main", "id" => nil},
            "attachment_refs" => attachments
          }}

  defp request_body({:run_control, action, run}) when action in [:pause, :continue, :stop],
    do: {:ok, %{"op" => "run.control", "action" => Atom.to_string(action), "run_id" => run}}

  defp request_body({:steer, run, node, text, attachments}) when is_list(attachments),
    do:
      {:ok,
       %{
         "op" => "run.steer",
         "run_id" => run,
         "node_id" => node,
         "text" => text,
         "attachment_refs" => attachments
       }}

  # `:always_allow` is the legacy name of `:approve_run` (this tool, this run).
  defp request_body({:resolve_approval, run, node, interaction, revision, :always_allow}),
    do: request_body({:resolve_approval, run, node, interaction, revision, :approve_run})

  defp request_body({:resolve_approval, run, node, interaction, revision, decision})
       when decision in [:approve, :approve_run, :always_prefix, :deny, :deny_stop],
       do:
         {:ok,
          %{
            "op" => "approval.resolve",
            "run_id" => run,
            "node_id" => node,
            "interaction_id" => interaction,
            "expected_revision" => revision,
            "decision" => Atom.to_string(decision)
          }}

  defp request_body(_), do: {:error, AdmissionError.new(:not_allowed)}

  defp response_body(%Message{type: :error, body: %{"op" => "error"} = body}, _request)
       when map_size(body) == 3 do
    case AdmissionError.decode(Map.delete(body, "op")) do
      {:ok, error} -> {:error, error}
      _ -> invalid()
    end
  end

  defp response_body(
         %Message{
           type: :response,
           body: %{"op" => "result", "response_kind" => kind, "value" => value} = body
         } = message,
         request
       )
       when map_size(body) == 3 do
    with {expected, module} <- Map.get(@responses, kind),
         true <- response_kind_matches?(expected, request),
         {:ok, dto} <- module.decode(value),
         true <- exact_wire_shape?(dto, value),
         :ok <- body_identity(dto, message.request_id),
         true <- scoped_body?(request.scope, dto),
         true <- response_matches?(request, dto),
         {:ok, dto} <- restore_identities(dto, message.request_id, request.request_id),
         dto = ui_response(dto, request),
         delivery = %Delivery{
           kind: :response,
           request_id: request.request_id,
           watch_ref: nil,
           scope: request.scope,
           generation: request.generation,
           revision: nil,
           sequence: nil,
           body: dto
         },
         {:ok, delivery} <- Delivery.validate(delivery) do
      {:ok, delivery}
    else
      _ -> invalid()
    end
  end

  defp response_body(_, _), do: invalid()
  defp body_identity(%{request_id: id}, id), do: :ok
  defp body_identity(%{request_id: _}, _), do: :error
  defp body_identity(_, _), do: :ok
  # Durable ledger outcomes written before command feedback remain readable.
  # No other omitted fields, including nested nullable fields, are accepted.
  defp exact_wire_shape?(%DTO.Outcome{feedback: nil} = dto, wire)
       when is_map(wire) and not is_map_key(wire, "feedback"),
       do: exact_wire_shape?(dto, Map.put(wire, "feedback", nil))

  defp exact_wire_shape?(%DTO.LibraryItem{form: nil} = dto, wire)
       when is_map(wire) and not is_map_key(wire, "form"),
       do: exact_wire_shape?(dto, Map.put(wire, "form", nil))

  defp exact_wire_shape?(%{__struct__: module} = dto, wire) when is_map(wire) do
    fields = Map.from_struct(dto)
    wire = with_optional_wire_keys(module, wire)

    map_size(fields) == map_size(wire) and
      Enum.all?(fields, fn {key, value} ->
        case Map.fetch(wire, Atom.to_string(key)) do
          {:ok, raw} -> exact_wire_shape?(value, raw)
          :error -> false
        end
      end)
  end

  defp exact_wire_shape?(values, wires) when is_list(values) and is_list(wires),
    do:
      length(values) == length(wires) and
        Enum.all?(Enum.zip(values, wires), fn {a, b} -> exact_wire_shape?(a, b) end)

  defp exact_wire_shape?(_, _), do: true

  defp with_optional_wire_keys(module, wire) do
    case Map.get(@optional_wire_keys, module) do
      nil ->
        wire

      keys ->
        defaults = module.__wire_defaults__()

        Enum.reduce(keys, wire, fn key, acc ->
          Map.put_new(acc, Atom.to_string(key), Keyword.fetch!(defaults, key))
        end)
    end
  end

  defp restore_identities(%{__struct__: _} = dto, wire, local) do
    Enum.reduce_while(Map.from_struct(dto), {:ok, dto}, fn {key, value}, {:ok, acc} ->
      result =
        if key == :request_id do
          cond do
            value == nil -> {:ok, nil}
            value == wire -> {:ok, local}
            true -> :error
          end
        else
          restore_identities(value, wire, local)
        end

      case result do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp restore_identities(values, wire, local) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case restore_identities(value, wire, local) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      _ -> :error
    end
  end

  defp restore_identities(value, _, _), do: {:ok, value}

  defp scoped_body?(scope, %DTO.WorkspaceSnapshot{} = page) do
    page.conversation_id == if(scope.kind == :conversation, do: scope.id, else: nil) and
      Enum.all?(page.runs ++ page.interactions ++ page.transcript.items, &scoped_item?(scope, &1))
  end

  defp scoped_body?(%{kind: :conversation, id: id}, %DTO.Outcome{feedback: feedback}),
    do: is_nil(feedback) or feedback.conversation_id in [nil, id]

  defp scoped_body?(_, %DTO.Outcome{}), do: true

  defp scoped_body?(scope, %DTO.ShellSnapshot{} = page),
    do: Enum.all?(page.runs, &scoped_item?(scope, &1))

  defp scoped_body?(scope, %DTO.RunDetailSnapshot{} = page),
    do:
      (is_nil(page.run) or scoped_item?(scope, page.run)) and
        Enum.all?(page.agents ++ page.transcript.items, &scoped_item?(scope, &1))

  defp scoped_body?(%{kind: :run, id: id}, %DTO.AgentDetail{run_id: run_id}), do: run_id == id
  defp scoped_body?(_scope, %DTO.AgentDetail{}), do: true
  defp scoped_body?(_scope, %DTO.LibrarySnapshot{}), do: true
  # The project's conversations: membership is the service's to resolve.
  defp scoped_body?(_scope, %DTO.ConversationList{}), do: true
  defp scoped_body?(scope, %{items: items}), do: Enum.all?(items, &scoped_item?(scope, &1))
  defp scoped_body?(_, _), do: true
  defp scoped_item?(%{kind: :global}, _), do: true

  # These DTOs contain run/conversation identities, not project membership.
  # The daemon resolves membership; this codec verifies the exact outer scope.
  defp scoped_item?(%{kind: :project}, _), do: true

  defp scoped_item?(%{kind: :conversation, id: id}, item),
    do: Map.get(item, :conversation_id) == id

  defp scoped_item?(%{kind: :run, id: id}, item), do: Map.get(item, :run_id, item.id) == id
  defp scoped_item?(_, _), do: false

  defp ui_response(%DTO.RunDetailSnapshot{transcript: transcript}, %Request{
         kind: {:query, :transcript, _, _, _, _},
         scope: %{kind: :run}
       }),
       do: transcript

  defp ui_response(dto, _), do: dto

  defp response_kind_matches?(:run_detail_snapshot, %Request{
         scope: %{kind: :run},
         expected_response: expected
       })
       when expected in [:workspace_snapshot, :transcript_window],
       do: true

  defp response_kind_matches?(expected, %Request{expected_response: expected}), do: true
  defp response_kind_matches?(_, _), do: false

  defp response_matches?(%Request{kind: {:query_detail, id, offset, bytes}}, body),
    do:
      body.offset == offset and byte_size(body.text) <= bytes and
        (body.state == :error or body.detail_ref.id == id)

  defp response_matches?(
         %Request{kind: {:feature_query, feature, _, _, size, bytes}},
         %DTO.LibrarySnapshot{} = body
       ),
       do:
         body.feature == feature and length(body.items) <= size and
           byte_size(Jason.encode!(wire_value(body))) <= bytes

  defp response_matches?(
         %Request{kind: {:agent_detail, run_id, node_id}},
         %DTO.AgentDetail{} = b
       ),
       do: b.state == :error or (b.run_id == run_id and b.agent_id == node_id)

  defp response_matches?(_, _), do: true

  defp wire_value(%_{} = value), do: value |> Map.from_struct() |> wire_value()

  defp wire_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, wire_value(v)} end)

  defp wire_value(value) when is_list(value), do: Enum.map(value, &wire_value/1)
  defp wire_value(value), do: value
  defp not_expired(deadline, now) when deadline > now, do: :ok
  defp not_expired(_, _), do: {:error, AdmissionError.new(:deadline_expired)}
  defp invalid, do: {:error, AdmissionError.new(:invalid_request)}

  @doc false
  def rejected_step(message, watch, kind, value, revision) do
    with {:kind, true} <- {:kind, @watch_bodies[wire_slot(watch)] == kind},
         {:module, {_expected, module}} <- {:module, @responses[kind]},
         {:decode, {:ok, dto}} <- {:decode, module.decode(value)},
         {:shape, true} <- {:shape, exact_wire_shape?(dto, value)},
         {:identities, {:ok, ^dto}} <- {:identities, restore_identities(dto, nil, nil)},
         {:scope, true} <- {:scope, scoped_body?(watch.scope, dto)},
         {:watermark, true} <- {:watermark, watermark_matches?(dto, message.sequence)},
         {:revision, true} <- {:revision, body_revision?(dto, revision)},
         {:encode, {:ok, bytes}} <- {:encode, Jason.encode(value)},
         {:bytes, true} <- {:bytes, byte_size(bytes) <= watch.byte_limit},
         {:pages, true} <- {:pages, page_sizes?(dto, watch.page_size)} do
      "none"
    else
      {:shape, false} -> "shape " <> shape_miss(value, kind)
      {step, _} -> Atom.to_string(step)
    end
  end

  # The first struct whose wire keys differ, by key name only.
  defp shape_miss(value, kind) do
    case @responses[kind] do
      {_expected, module} ->
        case module.decode(value) do
          {:ok, dto} -> first_shape_miss(dto, value) || "?"
          _ -> "?"
        end

      _ ->
        "?"
    end
  end

  defp first_shape_miss(%{__struct__: module} = dto, wire) when is_map(wire) do
    fields = Map.from_struct(dto)
    wire = with_optional_wire_keys(module, wire)
    names = MapSet.new(Map.keys(fields), &Atom.to_string/1)
    extra = wire |> Map.keys() |> Enum.reject(&MapSet.member?(names, &1))
    missing = names |> Enum.reject(&Map.has_key?(wire, &1))

    if extra != [] or missing != [] do
      "#{inspect(module)} extra #{inspect(extra)} missing #{inspect(missing)}"
    else
      Enum.find_value(fields, fn {key, value} ->
        first_shape_miss(value, Map.get(wire, Atom.to_string(key)))
      end)
    end
  end

  defp first_shape_miss(values, wires) when is_list(values) and is_list(wires) do
    if length(values) != length(wires),
      do: "list length",
      else: Enum.find_value(Enum.zip(values, wires), fn {a, b} -> first_shape_miss(a, b) end)
  end

  defp first_shape_miss(_, _), do: nil
end
