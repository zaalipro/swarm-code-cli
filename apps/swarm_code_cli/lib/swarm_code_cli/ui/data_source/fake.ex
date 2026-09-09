defmodule SwarmCodeCLI.UI.DataSource.Fake do
  @moduledoc """
  Client-owned synchronization over the separately owned canonical fake source.

  Source sequence is global and is checked before scope filtering. Each watch has
  a separate presentation sequence, seeded by its snapshot's canonical watermark
  and advanced only for visible facts. Both outer and Delta sequence are projected
  together. Resync replaces that seed with the new canonical watermark.

  Source calls run in monitored, deadline-bounded workers; watch, query and
  command callbacks acknowledge local admission immediately. Remote denials and
  deadline failures are correlated asynchronous deliveries. Only owner binding
  waits for its source acknowledgement. No canonical state is copied. Unwatch references and request IDs
  are single-use within this bounded client lifetime (256 each).
  """
  use GenServer
  @behaviour SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Delta, DTO, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Source}
  alias SwarmCodeCLI.UI.Intent

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def bind_owner(server, owner, ref), do: GenServer.call(server, {:bind, owner, ref}, :infinity)
  @impl true
  def watch(server, watch), do: GenServer.call(server, {:watch, watch}, :infinity)
  @impl true
  def unwatch(server, ref), do: GenServer.call(server, {:unwatch, ref})
  @impl true
  def query(server, req), do: GenServer.call(server, {:request, :query, req}, :infinity)
  @impl true
  def command(server, req), do: GenServer.call(server, {:request, :command, req}, :infinity)
  @impl true
  def cancel(server, id), do: GenServer.call(server, {:cancel, id})
  @impl true
  def close(server), do: GenServer.call(server, :close)

  @impl true
  def init(opts) do
    source = Keyword.get(opts, :source)
    epoch = Keyword.get(opts, :source_epoch)
    id = Keyword.get(opts, :client_id)
    timeout = Keyword.get(opts, :source_timeout, 1000)
    pid = resolve(source)

    if is_pid(pid) and Intent.valid_id?(epoch) and Intent.valid_id?(id) and is_integer(timeout) and
         timeout in 1..60_000 do
      {:ok,
       %{
         source: pid,
         source_monitor: Process.monitor(pid),
         epoch: epoch,
         id: id,
         adapter: self(),
         timeout: timeout,
         phase: :unbound,
         owner: nil,
         owner_monitor: nil,
         watches: %{},
         used_watches: MapSet.new(),
         requests: %{},
         used_requests: MapSet.new(),
         workers: %{},
         cursor: 0
       }}
    else
      {:stop, AdmissionError.new(:invalid_request)}
    end
  end

  @impl true
  def handle_call(:close, _, state), do: {:reply, :ok, shutdown(state)}
  def handle_call({:bind, _, _}, _, %{phase: :closed} = s), do: {:reply, {:error, :closed}, s}

  def handle_call({:bind, _, _}, _, %{phase: phase} = s) when phase != :unbound,
    do: {:reply, {:error, :already_bound}, s}

  def handle_call({:bind, owner, ref}, from, s) do
    pid = resolve(owner)

    if is_pid(pid) and Process.alive?(pid) and Intent.valid_id?(ref) do
      next = %{s | phase: :binding, owner: pid, owner_monitor: Process.monitor(pid)}

      {:noreply,
       work(next, {:bind, ref}, from, s.timeout, fn ->
         with :ok <- Source.attach(s.source, s.id, self_adapter(next)),
              %{source_epoch: epoch, sequence: cursor} <- Source.metadata(s.source),
              true <- epoch == s.epoch do
           {:bound, cursor}
         else
           _ -> {:error, :binding_failed}
         end
       end)}
    else
      {:reply, {:error, :binding_failed}, s}
    end
  end

  def handle_call({:unwatch, ref}, _, s) do
    GenServer.cast(s.source, {:unwatch, s.id, ref, self()})

    next =
      cancel_operations(s, fn key -> key == {:watch, ref} or match?({:resync, ^ref, _}, key) end)

    requests = Map.reject(next.requests, fn {_, req} -> req.kind == {:resync_watch, ref} end)
    {:reply, :ok, %{next | watches: Map.delete(next.watches, ref), requests: requests}}
  end

  def handle_call({:cancel, _}, _, %{phase: phase} = s) when phase != :bound,
    do: failure(if(phase == :closed, do: :closed, else: :not_bound), s)

  def handle_call({:cancel, id}, _, s) do
    next =
      cancel_operations(s, fn key -> key == {:request, id} or match?({:resync, _, ^id}, key) end)

    watches =
      Map.new(next.watches, fn {ref, e} ->
        {ref, if(e.resync == id, do: %{e | resync: nil}, else: e)}
      end)

    {:reply, :ok, %{next | requests: Map.delete(next.requests, id), watches: watches}}
  end

  def handle_call(_, _, %{phase: phase} = s) when phase != :bound,
    do: failure(if(phase == :closed, do: :closed, else: :not_bound), s)

  def handle_call({:watch, value}, _from, s) do
    with {:ok, w} <- Watch.validate(value),
         :ok <- check(not MapSet.member?(s.used_watches, w.watch_ref), :duplicate_watch),
         :ok <-
           check(
             map_size(s.watches) < 16 and MapSet.size(s.used_watches) < 256,
             :capacity_exceeded
           ) do
      entry = %{
        watch: w,
        phase: :pending,
        buffer: [],
        bytes: 0,
        sequence: 0,
        watermark: 0,
        revision: 0,
        resync: nil
      }

      next = %{
        s
        | watches: Map.put(s.watches, w.watch_ref, entry),
          used_watches: MapSet.put(s.used_watches, w.watch_ref)
      }

      {:reply, :ok,
       work(next, {:watch, w.watch_ref}, nil, s.timeout, fn ->
         Source.watch(s.source, s.id, w)
       end)}
    else
      {:error, code} -> failure(code, s)
    end
  end

  def handle_call({:request, mode, value}, _from, s) do
    with {:ok, req} <- Request.validate(value),
         :ok <- check(mode == :command == (req.expected_response == :outcome), :invalid_request),
         :ok <- check(req.deadline > Script.clock_ms(), :deadline_expired),
         :ok <- check(not MapSet.member?(s.used_requests, req.request_id), :request_conflict),
         :ok <-
           check(
             map_size(s.requests) < 64 and MapSet.size(s.used_requests) < 256,
             :capacity_exceeded
           ),
         :ok <- valid_resync(s, req) do
      next = %{
        s
        | requests: Map.put(s.requests, req.request_id, req),
          used_requests: MapSet.put(s.used_requests, req.request_id)
      }

      timeout = min(s.timeout, req.deadline - Script.clock_ms())

      case req.kind do
        {:resync_watch, ref} ->
          {:reply, :ok, resync(next, ref, req.request_id, nil, timeout)}

        _ ->
          {:reply, :ok,
           work(next, {:request, req.request_id}, nil, timeout, fn ->
             Source.request(s.source, s.id, req)
           end)}
      end
    else
      {:error, code} -> failure(code, s)
    end
  end

  def handle_call(_, _, s), do: failure(:invalid_request, s)

  # Capture the adapter PID outside workers without introducing a canonical copy.
  defp self_adapter(s), do: s.adapter

  defp work(s, key, from, timeout, fun) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          catch
            _, _ -> {:error, AdmissionError.new(:source_unavailable)}
          end

        send(parent, {:work, token, result})
      end)

    timer = Process.send_after(parent, {:expired, token}, timeout)

    put_in(s.workers[token], %{
      pid: pid,
      monitor: monitor,
      timer: timer,
      key: key,
      from: from,
      expires: System.monotonic_time(:millisecond) + timeout
    })
  end

  @impl true
  def handle_info({:work, token, result}, s) do
    case Map.pop(s.workers, token) do
      {nil, _} ->
        {:noreply, s}

      {job, jobs} ->
        cleanup_job(job)
        next = finished(%{s | workers: jobs}, job, result)

        next =
          if result == :ok and pending?(next, job.key), do: await_delivery(next, job), else: next

        {:noreply, next}
    end
  end

  def handle_info({:expired, token}, s) do
    case Map.pop(s.workers, token) do
      {nil, _} ->
        {:noreply, s}

      {job, jobs} ->
        cleanup_job(job)

        {:noreply,
         finished(%{s | workers: jobs}, job, {:error, AdmissionError.new(:deadline_expired)})}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) when ref == s.source_monitor do
    error = AdmissionError.new(:source_unavailable)

    Enum.each(s.requests, fn
      {_id, %Request{kind: {:resync_watch, _}}} -> :ok
      {id, _request} -> emit_failure(s, {:request, id}, error)
    end)

    {:noreply, shutdown(s)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) when ref == s.owner_monitor,
    do: {:noreply, shutdown(s)}

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Enum.find(s.workers, fn {_, j} -> j.monitor == ref end) do
      nil -> {:noreply, s}
      {token, _} -> handle_info({:expired, token}, s)
    end
  end

  def handle_info({:fake_source, id, deltas}, %{phase: :binding, id: id} = s)
      when is_list(deltas) do
    cursor =
      Enum.reduce(deltas, s.cursor, fn delta, cursor ->
        case Delta.validate(delta) do
          {:ok, d} -> if valid_epoch?(s, d.body), do: max(cursor, d.sequence), else: cursor
          _ -> cursor
        end
      end)

    {:noreply, %{s | cursor: cursor}}
  end

  def handle_info({:fake_source, id, raw}, %{phase: :bound, id: id} = s) do
    next =
      cond do
        is_list(raw) -> Enum.reduce(raw, s, &canonical/2)
        match?({:ok, _}, Delivery.validate(raw)) -> delivery(s, raw)
        true -> s
      end

    {:noreply, settle_delivered(next)}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp pending?(s, {:watch, ref}), do: match?(%{phase: :pending}, s.watches[ref])
  defp pending?(s, {:request, id}), do: Map.has_key?(s.requests, id)
  defp pending?(s, {:resync, ref, _}), do: match?(%{phase: :resyncing}, s.watches[ref])
  defp pending?(_, _), do: false

  defp await_delivery(s, job) do
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:expired, token},
        max(0, job.expires - System.monotonic_time(:millisecond))
      )

    put_in(s.workers[token], %{job | from: nil, timer: timer, monitor: nil, pid: nil})
  end

  defp settle_delivered(s) do
    workers =
      Enum.reduce(s.workers, %{}, fn {token, job}, acc ->
        if job.pid == nil and not pending?(s, job.key) do
          cleanup_job(job)
          acc
        else
          Map.put(acc, token, job)
        end
      end)

    %{s | workers: workers}
  end

  defp finished(s, %{key: {:bind, ref}} = job, {:bound, cursor}) do
    reply(job.from, {:ok, ref})
    %{s | phase: :bound, cursor: max(s.cursor, cursor)}
  end

  defp finished(s, %{key: {:bind, _}} = job, _) do
    reply(job.from, {:error, :binding_failed})
    shutdown(s)
  end

  defp finished(s, job, :ok) do
    reply(job.from, :ok)
    s
  end

  defp finished(s, job, result) do
    error =
      case result do
        {:error, %AdmissionError{} = e} -> e
        _ -> AdmissionError.new(:source_unavailable)
      end

    reply(job.from, {:error, error})
    if job.from == nil, do: emit_failure(s, job.key, error)

    case job.key do
      {:watch, ref} ->
        GenServer.cast(s.source, {:unwatch, s.id, ref, self()})
        %{s | watches: Map.delete(s.watches, ref)}

      {:request, id} ->
        %{s | requests: Map.delete(s.requests, id)}

      {:resync, ref, id} ->
        next = %{s | requests: Map.delete(s.requests, id)}
        if next.watches[ref], do: put_in(next.watches[ref].resync, nil), else: next
    end
  end

  defp emit_failure(s, {:request, id}, error) do
    if req = s.requests[id] do
      body = failure_body(req, error, s.epoch)

      emit(s, %Delivery{
        kind: :response,
        watch_ref: nil,
        request_id: id,
        scope: req.scope,
        generation: req.generation,
        revision: nil,
        sequence: nil,
        body: body
      })
    end
  end

  defp emit_failure(s, {kind, ref}, error) when kind == :watch do
    if e = s.watches[ref], do: emit(s, envelope(e.watch, :error, error))
  end

  defp emit_failure(s, {:resync, ref, _}, error), do: emit_failure(s, {:watch, ref}, error)

  defp failure_status(:stale_revision), do: :revision_conflict
  defp failure_status(:deadline_expired), do: :deadline_exceeded
  defp failure_status(code) when code in [:source_unavailable, :closed], do: :interrupted
  defp failure_status(_), do: :rejected

  defp failure_body(req, error, epoch) do
    attrs = [state: :error, request_id: req.request_id, error: error]

    case req.expected_response do
      :outcome ->
        %DTO.Outcome{
          request_id: req.request_id,
          status: failure_status(error.code),
          error: error
        }

      :transcript_window ->
        struct!(DTO.TranscriptWindow, attrs)

      :pending_interactions ->
        struct!(DTO.PendingInteractionWindow, attrs)

      :activity_snapshot ->
        struct!(DTO.ActivitySnapshot, attrs ++ [counts: %DTO.Counts{}])

      :shell_snapshot ->
        struct!(
          DTO.ShellSnapshot,
          attrs ++ [counts: %DTO.Counts{}, connection: %DTO.Connection{source_epoch: epoch}]
        )

      :workspace_snapshot ->
        struct!(
          DTO.WorkspaceSnapshot,
          attrs ++
            [
              conversation_id: if(req.scope.kind == :conversation, do: req.scope.id, else: nil),
              transcript: %DTO.TranscriptWindow{},
              runs_page: %DTO.PageInfo{},
              interactions_page: %DTO.PageInfo{}
            ]
        )

      :run_detail_snapshot ->
        struct!(DTO.RunDetailSnapshot, attrs ++ [transcript: %DTO.TranscriptWindow{}])

      :detail_window ->
        struct!(DTO.DetailWindow, attrs ++ [offset: elem(req.kind, 2)])
    end
  end

  defp canonical(delta, s) do
    with {:ok, d} <- Delta.validate(delta),
         true <- d.sequence > s.cursor and valid_epoch?(s, d.body) do
      gap = d.sequence != s.cursor + 1 or d.kind == :snapshot_required
      next = %{s | cursor: d.sequence}

      Enum.reduce(Map.keys(next.watches), next, fn ref, acc ->
        entry = acc.watches[ref]

        cond do
          d.sequence <= entry.watermark ->
            acc

          gap and entry.phase == :pending ->
            acc |> mark_gap(ref) |> resync(ref, nil, nil, acc.timeout)

          gap and entry.phase == :resyncing and entry.resync != nil ->
            restart_resync(acc, ref)

          gap ->
            mark_gap(acc, ref)

          entry.phase == :resyncing and entry.resync != nil ->
            buffer(acc, ref, d)

          entry.phase == :resyncing ->
            acc

          entry.phase == :pending ->
            buffer(acc, ref, d)

          true ->
            visible(acc, ref, d)
        end
      end)
    else
      _ -> s
    end
  end

  defp buffer(s, ref, delta) do
    e = s.watches[ref]
    bytes = e.bytes + :erlang.external_size(delta)

    if length(e.buffer) >= 128 or bytes > 1_048_576 do
      restart_resync(s, ref)
    else
      put_in(s.watches[ref], %{e | buffer: e.buffer ++ [delta], bytes: bytes})
    end
  end

  defp restart_resync(s, ref) do
    e = s.watches[ref]
    next = cancel_operations(s, fn key -> match?({:resync, ^ref, _}, key) end)
    next = %{next | requests: Map.delete(next.requests, e.resync)}

    next =
      put_in(next.watches[ref], %{
        e
        | watermark: max(e.watermark, s.cursor),
          buffer: [],
          bytes: 0,
          resync: nil
      })

    next |> mark_gap(ref) |> resync(ref, nil, nil, s.timeout)
  end

  defp visible(s, ref, d) do
    e = s.watches[ref]

    if d.revision >= e.revision and relevant?(e.watch, d) do
      sequence = e.sequence + 1
      out = envelope(e.watch, :delta, %{d | sequence: sequence}, d.revision, sequence)
      emit(s, out)
      put_in(s.watches[ref], %{e | sequence: sequence, revision: d.revision})
    else
      s
    end
  end

  defp relevant?(_, %{kind: k}) when k in [:counts_update, :connection], do: true
  defp relevant?(%{scope: %{kind: :global}}, _), do: true
  defp relevant?(%{scope: %{kind: :run, id: id}}, d), do: d.run_id == id
  defp relevant?(%{scope: %{kind: :conversation, id: id}}, d), do: d.conversation_id == id
  defp relevant?(_, _), do: false

  defp delivery(s, %Delivery{kind: :watch_ready, watch_ref: ref} = d) do
    case s.watches[ref] do
      %{watch: w, phase: phase} = e when phase in [:pending, :resyncing] ->
        if correlated?(w, d) and snapshot?(w.slot, d.body) and scoped_body?(w.scope, d.body) and
             valid_epoch?(s, d.body) and :erlang.external_size(d.body) <= w.byte_limit and
             is_nil(d.body.request_id) and d.revision >= e.revision and
             d.body.through_sequence >= e.watermark and (phase == :pending or e.resync != nil) do
          emit(s, d)

          next_entry = %{
            e
            | phase: :ready,
              buffer: [],
              bytes: 0,
              sequence: d.body.through_sequence,
              watermark: d.body.through_sequence,
              revision: d.revision,
              resync: nil
          }

          next = put_in(s.watches[ref], next_entry)
          next = %{next | requests: Map.delete(next.requests, e.resync)}

          Enum.reduce(e.buffer, next, fn delta, acc ->
            if delta.sequence > d.body.through_sequence, do: visible(acc, ref, delta), else: acc
          end)
        else
          s
        end

      _ ->
        s
    end
  end

  defp delivery(s, %Delivery{kind: :response, request_id: id} = d) do
    case s.requests[id] do
      %Request{} = req ->
        if correlated?(req, d) and response?(req.expected_response, d.body) and
             scoped_body?(req.scope, d.body) and
             valid_epoch?(s, d.body) and d.body.request_id == req.request_id and
             response_matches?(req, d.body) do
          emit(s, d)
          %{s | requests: Map.delete(s.requests, id)}
        else
          s
        end

      _ ->
        s
    end
  end

  defp delivery(s, _), do: s

  defp scoped_body?(scope, %DTO.WorkspaceSnapshot{} = page) do
    page.conversation_id == if(scope.kind == :conversation, do: scope.id, else: nil) and
      Enum.all?(page.runs ++ page.interactions ++ page.transcript.items, &scoped_item?(scope, &1))
  end

  defp scoped_body?(scope, %DTO.ShellSnapshot{} = page),
    do: Enum.all?(page.runs, &scoped_item?(scope, &1))

  defp scoped_body?(scope, %DTO.RunDetailSnapshot{} = page),
    do:
      (is_nil(page.run) or scoped_item?(scope, page.run)) and
        Enum.all?(page.agents ++ page.transcript.items, &scoped_item?(scope, &1))

  defp scoped_body?(scope, %{items: items}), do: Enum.all?(items, &scoped_item?(scope, &1))
  defp scoped_body?(_, _), do: true
  defp scoped_item?(%{kind: :global}, _), do: true

  defp scoped_item?(%{kind: :conversation, id: id}, item),
    do: Map.get(item, :conversation_id) == id

  defp scoped_item?(%{kind: :run, id: id}, item), do: Map.get(item, :run_id, item.id) == id
  defp scoped_item?(_, _), do: false

  defp valid_epoch?(s, %DTO.ShellSnapshot{connection: connection}),
    do: valid_epoch?(s, connection)

  defp valid_epoch?(s, %DTO.Connection{source_epoch: epoch}), do: s.epoch == epoch
  defp valid_epoch?(_, _), do: true

  defp response_matches?(%Request{kind: {:query_detail, id, offset, bytes}}, body),
    do:
      body.offset == offset and byte_size(body.text) <= bytes and
        (body.state == :error or body.detail_ref.id == id)

  defp response_matches?(_, _), do: true

  defp resolve(value) do
    GenServer.whereis(value)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp correlated?(expected, d),
    do: expected.scope == d.scope and expected.generation == d.generation

  defp snapshot?(:shell, body), do: match?(%DTO.ShellSnapshot{}, body)
  defp snapshot?(:workspace, body), do: match?(%DTO.WorkspaceSnapshot{}, body)
  defp snapshot?(:activity, body), do: match?(%DTO.ActivitySnapshot{}, body)
  defp snapshot?(:inspector, body), do: match?(%DTO.RunDetailSnapshot{}, body)
  defp response?(:detail_window, body), do: match?(%DTO.DetailWindow{}, body)
  defp response?(:outcome, body), do: match?(%DTO.Outcome{}, body)
  defp response?(:shell_snapshot, body), do: snapshot?(:shell, body)
  defp response?(:workspace_snapshot, body), do: snapshot?(:workspace, body)
  defp response?(:activity_snapshot, body), do: snapshot?(:activity, body)
  defp response?(:run_detail_snapshot, body), do: snapshot?(:inspector, body)
  defp response?(:transcript_window, body), do: match?(%DTO.TranscriptWindow{}, body)
  defp response?(:pending_interactions, body), do: match?(%DTO.PendingInteractionWindow{}, body)
  defp response?(_, _), do: false

  defp valid_resync(s, %Request{kind: {:resync_watch, ref}} = req) do
    case s.watches[ref] do
      %{watch: w, phase: :resyncing, resync: nil} -> check(correlated?(w, req), :invalid_request)
      _ -> {:error, :invalid_request}
    end
  end

  defp valid_resync(_, _), do: :ok

  defp mark_gap(s, ref) do
    e = s.watches[ref]

    if e.phase == :resyncing do
      put_in(s.watches[ref], %{e | watermark: max(e.watermark, s.cursor), buffer: [], bytes: 0})
    else
      emit(s, envelope(e.watch, :resyncing, nil))

      put_in(s.watches[ref], %{
        e
        | phase: :resyncing,
          buffer: [],
          bytes: 0,
          watermark: max(e.watermark, s.cursor)
      })
    end
  end

  defp resync(s, ref, id, from, timeout) do
    e = s.watches[ref]
    # A cancelled or expired attempt can still deliver its snapshot. Every
    # attempt requires coverage through the current canonical cursor; facts
    # arriving after this point remain buffered until that snapshot installs.
    next =
      put_in(s.watches[ref], %{e | resync: id || :internal, watermark: max(e.watermark, s.cursor)})

    work(next, {:resync, ref, id}, from, timeout, fn ->
      with :ok <- Source.unwatch(s.source, s.id, ref), do: Source.watch(s.source, s.id, e.watch)
    end)
  end

  defp envelope(w, kind, body, revision \\ nil, sequence \\ nil),
    do: %Delivery{
      kind: kind,
      watch_ref: w.watch_ref,
      request_id: nil,
      scope: w.scope,
      generation: w.generation,
      revision: revision,
      sequence: sequence,
      body: body
    }

  defp emit(%{phase: :bound} = s, d), do: send(s.owner, {:swarm_code_ui_data, s.epoch, d})
  defp emit(_, _), do: :ok
  defp check(true, _), do: :ok
  defp check(false, code), do: {:error, code}
  defp failure(code, s), do: {:reply, {:error, AdmissionError.new(code)}, s}
  defp reply(nil, _), do: :ok
  defp reply(from, value), do: GenServer.reply(from, value)

  defp cleanup_job(job) do
    Process.cancel_timer(job.timer)
    if job.monitor, do: Process.demonitor(job.monitor, [:flush])
    if is_pid(job.pid) and Process.alive?(job.pid), do: Process.exit(job.pid, :kill)
  end

  defp cancel_operations(s, predicate) do
    jobs =
      Enum.reduce(s.workers, %{}, fn {token, job}, acc ->
        if predicate.(job.key) do
          cleanup_job(job)

          reply(
            job.from,
            if(match?({:bind, _}, job.key),
              do: {:error, :closed},
              else: {:error, AdmissionError.new(:closed)}
            )
          )

          acc
        else
          Map.put(acc, token, job)
        end
      end)

    %{s | workers: jobs}
  end

  defp shutdown(%{phase: :closed} = s), do: s

  defp shutdown(s) do
    Enum.each(s.watches, fn {_, e} -> emit(s, envelope(e.watch, :closed, nil)) end)
    next = cancel_operations(s, fn _ -> true end)
    GenServer.cast(s.source, {:detach, s.id, self()})
    if s.owner_monitor, do: Process.demonitor(s.owner_monitor, [:flush])
    Process.demonitor(s.source_monitor, [:flush])
    %{next | phase: :closed, owner: nil, owner_monitor: nil, watches: %{}, requests: %{}}
  end

  @impl true
  def terminate(_, s), do: shutdown(s)
  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, %{
        phase: status.state.phase,
        watches: map_size(status.state.watches),
        requests: map_size(status.state.requests)
      })
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, [])

  @impl true
  def consume(server, receipt, disposition) when disposition in [:applied, :discarded] do
    if is_pid(resolve(server)) and is_reference(receipt),
      do: :ok,
      else: {:error, AdmissionError.new(:invalid_request)}
  end

  def consume(_server, _receipt, _disposition), do: {:error, AdmissionError.new(:invalid_request)}
end
