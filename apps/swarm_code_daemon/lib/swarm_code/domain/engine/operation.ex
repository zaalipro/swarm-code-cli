defmodule SwarmCode.Domain.Engine.Operation do
  @moduledoc """
  Runs one unit of work (an LLM call or a tool call) in its own Task under the agent's
  Task.Supervisor, with its own node, progress reporting, approval gate and result delivery.
  """

  alias SwarmCode.Domain.Engine.{Policy, RunServer}
  alias SwarmCode.Domain.LLM
  alias SwarmCode.Domain.Tools
  alias SwarmCode.Domain.Tools.Ref

  @type work ::
          {:llm, LLM.Request.t()}
          | {:tool, Ref.t() | nil, map(), map()}
          | {:invalid_args, String.t(), String.t(), String.t() | nil}

  @doc """
  Registers the op node and starts the task. `owner` receives
  `{:op_event, node_id, event}` while streaming and `{:op_done, node_id, result}` at the end.
  """
  @spec start(GenServer.name(), pid(), %{
          run_id: String.t(),
          parent_id: String.t(),
          op_type: String.t(),
          title: String.t(),
          work: work
        }) :: {:ok, String.t()}
  def start(ops_sup, owner, %{
        run_id: run_id,
        parent_id: parent_id,
        op_type: op_type,
        title: title,
        work: work
      }) do
    progress0 = if Tools.determinate?(op_type), do: 0, else: nil

    {:ok, node} =
      RunServer.register_node(run_id, %{
        kind: "op",
        op_type: op_type,
        title: title,
        parent_id: parent_id,
        progress: progress0,
        status: "running",
        input: input_of(work)
      })

    {:ok, _pid} =
      Task.Supervisor.start_child(ops_sup, fn -> run(owner, run_id, node.id, op_type, work) end)

    {:ok, node.id}
  end

  # Spec 45 §8.3: the tool arguments travel with the op node (JSON, at most
  # 8 KB) so the Inspector's Input tab survives the run. An `llm` step stores
  # nothing — its request is the whole history.
  @input_bytes 8_192

  defp input_of({:tool, _ref, args, _ctx}) when is_map(args) do
    case Jason.encode(args) do
      {:ok, json} -> window(json, @input_bytes)
      {:error, _} -> nil
    end
  end

  defp input_of(_work), do: nil

  # A UTF-8-safe byte prefix — the same cut `SwarmCode.Domain.Format.window/2`
  # makes; the engine does not depend on the web layer.
  defp window(text, bytes) when byte_size(text) <= bytes, do: text
  defp window(text, bytes), do: valid_prefix(text, bytes, 0)

  # Spec 51 §2.1: the prefix is copied — a sub-binary of a 200 KB `write_file`
  # argument would keep the whole file alive in the node for the run's life.
  defp valid_prefix(text, bytes, dropped) when dropped <= 3 do
    prefix = binary_part(text, 0, bytes - dropped)

    if String.valid?(prefix),
      do: :binary.copy(prefix),
      else: valid_prefix(text, bytes, dropped + 1)
  end

  @doc false
  def run(owner, run_id, id, op_type, work) do
    RunServer.update_node(run_id, id, %{pid: self()})

    # Spec 43 §1.6 (C7): a build printing ten thousand lines used to send ten
    # thousand casts through the RunServer's normaliser; the flush coalesced
    # the broadcasts, not that work. One cast per 50 ms per op; the last one
    # (`pct == 100`, or whatever `finalize/1` writes) always lands.
    progress = fn pct, detail ->
      now = System.monotonic_time(:millisecond)

      if pct == 100 or now - Process.get(:sc_progress_at, 0) >= 50 do
        Process.put(:sc_progress_at, now)
        RunServer.update_node(run_id, id, %{progress: pct, detail: detail})
      end

      :ok
    end

    result =
      try do
        do_work(owner, run_id, id, op_type, work, progress)
      rescue
        e -> {:error, "crashed: " <> Exception.message(e)}
      catch
        # Spec 36 §A4 / spec 51 §7.6: a shutdown is the supervisor ending this
        # task, not a failure — the AgentServer that owned it is already gone
        # (AgentSup is one_for_all) and the stop path persisted `stopped`. Die
        # with the reason; write nothing; send nothing.
        :exit, reason
        when reason == :shutdown or (is_tuple(reason) and elem(reason, 0) == :shutdown) ->
          exit(reason)

        kind, value ->
          {:error, "crashed: #{inspect({kind, value})}"}
      end

    RunServer.update_node(run_id, id, finalize(result))
    send(owner, {:op_done, id, owner_view(result)})
    result
  end

  # Spec 43 §1.1: the agent never reads the reasoning text (the RunServer got
  # its preview above; the signed thinking travels in `provider_blocks`), so it
  # is not copied into the agent's mailbox and history.
  defp owner_view({:ok, %LLM.Result{} = r}), do: {:ok, %{r | reasoning: ""}}
  defp owner_view(result), do: result

  # A transport retry is not a failure: the op node says so (warn colour) and
  # the agent's turn is not consumed (spec 11 §7.3).
  #
  # Spec 43 §1.1: streamed text goes straight to the RunServer — the agent never
  # read it, it only forwarded it, and that hop copied every token once more.
  # Spec 51 §6.3: nothing at all goes to the owner while the stream runs.
  defp do_work(_owner, run_id, id, _op_type, {:llm, request}, _progress) do
    LLM.stream(request, fn
      {:retry, attempt, of, reason} ->
        RunServer.update_node(run_id, id, %{
          status: "retrying",
          detail: "retrying #{attempt}/#{of} · #{reason}"
        })

      {:text_delta, text} ->
        RunServer.text_delta(run_id, id, text)

      {:reasoning_delta, text} ->
        RunServer.reasoning_delta(run_id, id, text)

      {:text_reset} ->
        RunServer.text_reset(run_id, id)

      {:reasoning_reset} ->
        RunServer.reasoning_reset(run_id, id)

      # Spec 51 §6.3: nothing is left for the agent to act on — the `{:usage, …}`
      # hop is gone and `Result.usage` is read at `op_done`. The clause stays
      # tolerant so a provider module (or a fake) that emits one more event kind
      # cannot crash the op.
      _other ->
        :ok
    end)
  end

  defp do_work(_owner, _run_id, _id, op_type, {:tool, nil, _args, _ctx}, _progress) do
    {:error, "unknown tool #{op_type}"}
  end

  # The provider streamed `arguments` that are not a JSON object. Say so, and
  # show the model the head of what it actually sent, so the next call is fixed
  # instead of identical (spec 20 review, 2026-08-23).
  defp do_work(_owner, _run_id, _id, _op_type, {:invalid_args, name, reason, raw}, _progress) do
    {:error,
     "the arguments of #{name} were not valid JSON (#{reason}) — resend the call with a " <>
       "single well-formed JSON object, escaping every newline and quote inside string values" <>
       raw_hint(raw)}
  end

  defp do_work(_owner, run_id, id, _op_type, {:tool, %Ref{} = ref, args, ctx}, progress) do
    ctx = Map.put(ctx, :node_id, id)
    permission = Ref.permission(ref, args)

    case Policy.decide(current_mode(ctx), permission, MapSet.new()) do
      {:deny, msg} ->
        {:error, msg}

      :allow ->
        Tools.run(ref, args, ctx, progress)

      :ask ->
        case RunServer.request_approval(run_id, id, permission) do
          :approved -> Tools.run(ref, args, ctx, progress)
          :denied -> {:error, "denied by user"}
          :timeout -> {:error, "approval timed out after 10 minutes"}
        end
    end
  end

  defp raw_hint(raw) when is_binary(raw) and raw != "" do
    head = if byte_size(raw) > 200, do: binary_part(raw, 0, 200) <> "…", else: raw
    ". Received: " <> head
  end

  defp raw_hint(_raw), do: ""

  # The project's approval mode can be changed from the composer while a run is
  # going; read the current value per op so the change applies to the next op
  # immediately. Spec 39 §1.1: a research run is the exception — it runs
  # against a scratch %Project{} whose mode was set in memory (spec 24 §3.1),
  # and the row it borrows belongs to the user's "No project" chats.
  defp current_mode(%{run_kind: "research"} = ctx), do: ctx.approval_mode

  defp current_mode(ctx) do
    with id when is_binary(id) <- Map.get(ctx, :project_id),
         %{approval_mode: mode} when is_binary(mode) <- SwarmCode.Domain.Projects.get_cached(id) do
      mode
    else
      _ -> ctx.approval_mode
    end
  end

  # `detail` keeps the model's thinking whenever it produced any: an llm op that
  # only called tools has no text at all, and overwriting `detail` with it left
  # the expanded step empty (spec 06 §11).
  defp finalize({:ok, %LLM.Result{} = r}) do
    %{
      status: "done",
      progress: 100,
      result: r.text,
      detail: llm_detail(r),
      tokens_in: r.usage.input,
      tokens_out: r.usage.output,
      finished_at: now()
    }
  end

  # Spec 51 §2.2 (c): the RunServer's `normalize/1` used to receive — and the
  # cast used to copy — the whole tool output twice; it is cut and owned here.
  # The agent still gets the full text through `owner_view/1`: its history needs
  # it (`Tools` bounds it at 100 000 chars and `Context.compress` folds it later).
  @result_chars 20_000
  # The RunServer's `@detail_scan_bytes`; it re-cuts to 160 chars.
  @detail_scan 1_280

  defp finalize({:ok, text}) do
    text = to_string(text)

    %{
      status: "done",
      progress: 100,
      result: own(String.slice(text, 0, @result_chars), text),
      detail: own(String.slice(text, 0, @detail_scan), text),
      finished_at: now()
    }
  end

  defp finalize({:error, msg}) do
    msg = to_string(msg)

    %{
      status: "failed",
      progress: 100,
      error: own(String.slice(msg, 0, @result_chars), msg),
      detail: own(String.slice(msg, 0, @detail_scan), msg),
      finished_at: now()
    }
  end

  # Spec 51 §2.1: a slice shorter than its parent is a sub-binary pinning the
  # parent; copy it so the node owns its bytes.
  defp own(slice, parent) when byte_size(slice) < byte_size(parent), do: :binary.copy(slice)
  defp own(slice, _parent), do: slice

  defp llm_detail(%LLM.Result{reasoning: reasoning})
       when is_binary(reasoning) and reasoning != "",
       do: reasoning

  defp llm_detail(%LLM.Result{text: text}), do: text

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
