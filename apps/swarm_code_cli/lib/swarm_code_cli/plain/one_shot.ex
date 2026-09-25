defmodule SwarmCodeCLI.Plain.OneShot do
  @moduledoc """
  `swarmcode -p PROMPT`: one turn in the saved conversation with nobody at the
  keyboard.

  The prompt is sent the way the composer sends it, through the same pure
  reducer, read model and request resolver the full-screen view uses; this
  process only owns them. The assistant's answer is written to `output` as it
  streams (with `format: :json`, once at the end, as one JSON object).

  The project's approval mode decides what needs a person. Whatever still does
  is denied, with one line on `error` naming what was denied; a question cannot
  be answered either, so the run is stopped and the line says so. The session
  ends when the run does: the observer receives
  `{:one_shot, pid, {:finished, code}}`, `0` when every run the prompt started
  is done and `1` when one failed, was stopped, or the prompt was not sent.
  """
  use GenServer

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Drafts,
    Editor,
    EffectRunner,
    Init,
    Intent,
    Keymap,
    ReadModel,
    Reducer,
    Size,
    State
  }

  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{DataBridge, Delivery, DTO, Request}

  @terminal [:done, :failed, :stopped, :interrupted, :superseded]
  # A model that keeps asking for what nobody can approve is stopped rather
  # than denied forever.
  @max_denials 8
  @detail_page 16_384
  @own_deadline_ms 35_000
  @bind_ref "one-shot-bind"
  # The reducer lays the conversation out as if on a terminal this size; it
  # is never drawn, but mutations are only admitted where they would show.
  @size %Size{columns: 120, rows: 40}

  @doc """
  Runs the turn to its end and returns the exit code.

  Options: `data_source`, `source_epoch`, `conversation_id`, `prompt`, and
  optionally `format` (`:text` | `:json`), `output` and `error` (IO devices),
  `progress` (tool lines on `error`), `clock` (a zero-arity millisecond clock).
  """
  @spec run(keyword()) :: 0 | 1
  def run(options) do
    {:ok, pid} = GenServer.start(__MODULE__, Keyword.put(options, :observer, self()))
    monitor = Process.monitor(pid)

    receive do
      {:one_shot, ^pid, {:finished, code}} ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        code

      {:DOWN, ^monitor, :process, ^pid, _} ->
        1
    end
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    epoch = Keyword.fetch!(options, :source_epoch)
    conversation = Keyword.fetch!(options, :conversation_id)
    prompt = Keyword.fetch!(options, :prompt)
    format = Keyword.get(options, :format, :text)

    if Intent.valid_id?(epoch) and Intent.valid_id?(conversation) and Intent.valid_text?(prompt) and
         format in [:text, :json] do
      client = Keyword.fetch!(options, :data_source)

      state = %{
        phase: :binding,
        client: client,
        client_monitor: Process.monitor(client),
        epoch: epoch,
        conversation: conversation,
        prompt: prompt,
        format: format,
        output: Keyword.get(options, :output, :standard_io),
        error: Keyword.get(options, :error, :standard_error),
        progress?: Keyword.get(options, :progress, false) == true,
        clock: Keyword.get(options, :clock, fn -> System.system_time(:millisecond) end),
        observer: Keyword.get(options, :observer),
        ui: nil,
        dispatch: nil,
        runs: [],
        # Requests this process sent itself (the completion query and detail
        # pages); their answers never reach the reducer.
        own: %{},
        # Deny/stop commands sent for an interaction, by request id.
        answers: %{},
        handled: MapSet.new(),
        denied: [],
        denials: 0,
        question: nil,
        texts: %{},
        answer_order: [],
        last_written: nil,
        # stdout does not end with a newline yet (the answer gets one at the end).
        mid_line?: false,
        # The terminal's cursor is at the start of a line: stderr lines after
        # an answer that stopped mid-line begin on a line of their own.
        fresh_line?: true,
        # This process stopped the run itself and has said why.
        stopped?: false,
        announced: MapSet.new(),
        details: [],
        sequence: 0
      }

      {:ok, state, {:continue, :bind}}
    else
      {:stop, :invalid_one_shot}
    end
  end

  @impl true
  def handle_continue(:bind, state) do
    case safely(fn -> DataSource.bind_owner(state.client, self(), @bind_ref) end) do
      {:ok, @bind_ref} ->
        {ui, effects} =
          Reducer.init(%Init{
            size: @size,
            capabilities: %Capabilities{size: @size},
            source_epoch: state.epoch,
            destination: {:conversation, state.conversation},
            focus: "composer",
            now: state.clock.()
          })

        state = %{state | ui: ui, phase: :opening}
        run_effects(state, effects)
        {:noreply, state}

      _ ->
        stop(finish(state, 1, "the saved session could not be opened."))
    end
  end

  @impl true
  def handle_info({:swarm_code_ui_data, _, receipt, _} = envelope, %{phase: phase} = state)
      when phase not in [:binding, :finished] do
    {next, disposition} =
      case DataBridge.normalize(envelope, state.epoch) do
        {:ok, {:data, delivery}} -> {deliver(state, delivery), :applied}
        _ -> {state, :discarded}
      end

    case safely(fn -> DataSource.consume(state.client, receipt, disposition) end) do
      :ok -> continue(next)
      _ -> stop(finish(next, 1, "the session stopped answering."))
    end
  end

  def handle_info({:swarm_code_ui_data, _, _} = envelope, %{phase: phase} = state)
      when phase not in [:binding, :finished] do
    case DataBridge.normalize(envelope, state.epoch) do
      {:ok, {:data, delivery}} -> continue(deliver(state, delivery))
      _ -> {:noreply, state}
    end
  end

  def handle_info(
        {:swarm_code_ui_closed, client, epoch},
        %{client: client, epoch: epoch} = state
      ),
      do: stop(finish(state, 1, "the session closed before the run finished."))

  def handle_info({:DOWN, monitor, :process, _, _}, %{client_monitor: monitor} = state),
    do: stop(finish(state, 1, "the session closed before the run finished."))

  # The source answers every request, if only with a failure; one that never
  # does must not keep the command waiting.
  def handle_info({:own_deadline, id}, %{own: own} = state) when is_map_key(own, id) do
    {purpose, own} = Map.pop(own, id)
    continue(own_response(%{state | own: own}, purpose, :deadline))
  end

  def handle_info(_, state), do: {:noreply, state}

  defp continue(%{phase: :finished} = state), do: stop(state)
  defp continue(state), do: {:noreply, state}
  defp stop(state), do: {:stop, :normal, state}

  # -- deliveries -------------------------------------------------------------

  defp deliver(state, %Delivery{kind: :response, request_id: id} = delivery)
       when is_map_key(state.own, id) do
    {purpose, own} = Map.pop(state.own, id)
    own_response(%{state | own: own}, purpose, delivery.body)
  end

  defp deliver(state, %Delivery{} = delivery) do
    {state, _effects} = update(state, {:data, delivery})

    state
    |> observe_outcome(delivery)
    |> check()
  end

  defp observe_outcome(%{dispatch: id} = state, %Delivery{
         kind: :response,
         request_id: id,
         body: %DTO.Outcome{} = outcome
       })
       when is_binary(id) do
    case outcome do
      %{status: :accepted, identifiers: []} ->
        # A slash command answers at once and starts nothing.
        text = if outcome.feedback, do: outcome.feedback.text, else: ""
        finish(reconcile(state, "command", text), 0)

      %{status: :accepted, identifiers: ids} ->
        %{state | phase: :running, runs: Enum.take(ids, 8)}

      _ ->
        finish(state, 1, "the prompt was not sent: " <> outcome_words(outcome) <> ".")
    end
  end

  defp observe_outcome(state, %Delivery{
         kind: :response,
         request_id: id,
         body: %DTO.Outcome{} = outcome
       })
       when is_map_key(state.answers, id) do
    {interaction, answers} = Map.pop(state.answers, id)
    state = %{state | answers: answers}

    if outcome.status == :accepted do
      state
    else
      stop_run(state, interaction.run_id, "the approval could not be denied, so the run")
    end
  end

  defp observe_outcome(state, _), do: state

  defp check(%{phase: :opening} = state) do
    watch = state.ui.watches.workspace

    case {watch.status, Map.get(state.ui.read_model.snapshots, :workspace)} do
      {:ready, %DTO.WorkspaceSnapshot{conversation_id: id}} when id == state.conversation ->
        send_prompt(state)

      {:error, _} ->
        finish(state, 1, "the conversation could not be opened.")

      _ ->
        state
    end
  end

  defp check(%{phase: :running} = state) do
    state
    |> print_answer(answer_items(state))
    |> announce_tools()
    |> answer_interactions()
    |> maybe_settle()
  end

  defp check(state), do: state

  # -- sending ----------------------------------------------------------------

  # cli74: the settings layer needs the full-screen terminal; a one-shot
  # says so and sends nothing.
  defp send_prompt(%{prompt: prompt} = state) when is_binary(prompt) do
    if SwarmCodeCLI.UI.Keymap.settings_command?(prompt),
      do: finish(state, 1, SwarmCodeCLI.Plain.Command.settings_words()),
      else: send_line(state)
  end

  defp send_line(state) do
    key = {state.conversation, :main}
    {state, _} = update(state, {:editor, key, {:paste, state.prompt}})
    text = Editor.text(Drafts.fetch(state.ui.drafts, key).editor)
    intent = {:dispatch, :send, text, :main, []}
    id = elem(State.next_id(state.ui, :request), 0)
    {state, effects} = update(state, {:invoke, intent, id})

    if Enum.any?(effects, &match?({:command, %Request{request_id: ^id}}, &1)) do
      %{state | phase: :sending, dispatch: id}
    else
      finish(state, 1, "the conversation cannot take a prompt right now" <> busy(state) <> ".")
    end
  end

  defp busy(state) do
    if Keymap.live_turn(state.ui),
      do: " (a turn is still running; try --new)",
      else: ""
  end

  # -- the answer -------------------------------------------------------------

  # The answer is the run's assistant message: its item id is the message's,
  # not the agent node's (a worker's own reply is an agent node, and so is the
  # lead's before its message exists).
  defp answer_items(state) do
    model = state.ui.read_model

    for item <- ReadModel.items(model, :workspace),
        item.run_id in state.runs,
        item.role == :assistant and item.kind == :text and item.id != item.node_id,
        do: ReadModel.transcript_item(model, item.id)
  end

  defp print_answer(state, items),
    do: Enum.reduce(items, state, &reconcile(&2, &1.id, &1.text))

  # What was written is never taken back: a longer text continues it, a
  # shorter one is the same answer cut to a preview, and anything else is a
  # restarted attempt, written again after a line saying so.
  defp reconcile(state, id, text) do
    known = Map.get(state.texts, id)

    cond do
      known == nil ->
        state = %{state | answer_order: state.answer_order ++ [id]}
        write_answer(%{state | texts: Map.put(state.texts, id, "")}, id, text)

      String.starts_with?(text, known) ->
        write_answer(
          state,
          id,
          binary_part(text, byte_size(known), byte_size(text) - byte_size(known))
        )

      String.starts_with?(known, text) ->
        state

      true ->
        state = say(state, "the answer restarted.")
        # The new attempt starts on a line of its own in the output too.
        if state.format == :text and state.mid_line?, do: write(state.output, "\n")
        state = %{state | texts: Map.put(state.texts, id, ""), mid_line?: false}
        write_answer(%{state | last_written: nil}, id, text)
    end
  end

  defp write_answer(state, _id, ""), do: state

  defp write_answer(state, id, chunk) do
    texts = Map.update(state.texts, id, chunk, &(&1 <> chunk))

    if state.format == :text do
      separator = if state.last_written not in [nil, id], do: "\n\n", else: ""
      text = separator <> clean(chunk)
      # The answer starts at its first visible line.
      text = if state.last_written == nil, do: String.trim_leading(text, "\n"), else: text

      if text != "" do
        write(state.output, text)
        ends? = String.ends_with?(text, "\n")
        %{state | texts: texts, last_written: id, mid_line?: not ends?, fresh_line?: ends?}
      else
        %{state | texts: texts}
      end
    else
      %{state | texts: texts, last_written: id}
    end
  end

  defp announce_tools(%{progress?: false} = state), do: state

  defp announce_tools(state) do
    model = state.ui.read_model

    Enum.reduce(ReadModel.items(model, :workspace), state, fn item, state ->
      if item.run_id in state.runs and item.kind == :tool and
           not MapSet.member?(state.announced, item.id) do
        title =
          case item.tool do
            %DTO.ToolCall{title: title} when title != "" -> title
            %DTO.ToolCall{name: name} -> name
            _ -> first_line(item.text)
          end

        say(%{state | announced: MapSet.put(state.announced, item.id)}, "· " <> title, false)
      else
        state
      end
    end)
  end

  # -- approvals and questions ------------------------------------------------

  defp answer_interactions(state) do
    state.ui.read_model.interactions
    |> Map.values()
    |> Enum.filter(
      &(&1.state == :pending and &1.run_id in state.runs and
          not MapSet.member?(state.handled, {&1.id, &1.expected_revision}))
    )
    |> Enum.sort_by(&{&1.created_at, &1.id})
    |> Enum.reduce(state, fn interaction, state ->
      state = %{
        state
        | handled: MapSet.put(state.handled, {interaction.id, interaction.expected_revision})
      }

      answer(state, interaction)
    end)
  end

  defp answer(%{phase: :running} = state, %DTO.PendingInteraction{kind: :question} = item) do
    prompt = if item.question, do: first_line(item.question.prompt), else: "a question"
    state = %{state | question: prompt}

    stop_run(
      state,
      item.run_id,
      "the run asked \"#{prompt}\" and nobody is here to answer, so it"
    )
  end

  defp answer(%{phase: :running, denials: denials} = state, item) when denials >= @max_denials,
    do: stop_run(state, item.run_id, "#{@max_denials} approvals were denied, so the run")

  defp answer(%{phase: :running} = state, %DTO.PendingInteraction{kind: :approval} = item) do
    decisions = Keymap.decisions(item)

    decision =
      cond do
        :deny in decisions -> :deny
        :deny_stop in decisions -> :deny_stop
        true -> nil
      end

    what = describe(item)

    if decision do
      intent =
        {:resolve_approval, item.run_id, item.node_id, item.id, item.expected_revision, decision}

      id = elem(State.next_id(state.ui, :request), 0)
      {state, effects} = update(state, {:invoke, intent, id})

      if Enum.any?(effects, &match?({:command, %Request{request_id: ^id}}, &1)) do
        state = %{
          state
          | answers: Map.put(state.answers, id, item),
            denials: state.denials + 1,
            denied: Enum.take(state.denied ++ [what], 32)
        }

        say(
          state,
          "denied #{what.label}: nobody is here to approve it." <> denial_hint(mode(state))
        )
      else
        stop_run(state, item.run_id, "#{what.label} could not be denied, so the run")
      end
    else
      stop_run(state, item.run_id, "#{what.label} needs a person, so the run")
    end
  end

  defp answer(state, _), do: state

  @doc """
  What the denial line suggests, from the project's approval mode (pass70 Q8):
  a project already on `auto` was told to switch to "auto or full".
  """
  @spec denial_hint(term()) :: String.t()
  def denial_hint(mode) when mode in [:auto, "auto"],
    do: " /approval full runs every command without asking."

  def denial_hint(mode) when mode in [:full_access, "full_access"], do: ""
  def denial_hint(_mode), do: " /approval auto or full allows more without asking."

  defp mode(state) do
    case Map.get(state.ui.read_model.snapshots, :workspace) do
      %{} = workspace -> Map.get(workspace, :approval_mode)
      _ -> nil
    end
  end

  defp describe(%DTO.PendingInteraction{approval: %DTO.Approval{} = approval}) do
    subject = approval.command || argument(approval.arguments_preview)
    label = String.trim(approval.tool <> " " <> first_line(subject || ""))

    %{
      tool: approval.tool,
      command: approval.command,
      label: if(label == "", do: "a tool call", else: label)
    }
  end

  defp describe(_), do: %{tool: nil, command: nil, label: "a tool call"}

  # A tool's arguments arrive as a JSON preview; its command or path is what
  # a person would read, and the preview itself when it is neither.
  defp argument(preview) do
    case Jason.decode(preview) do
      {:ok, %{"command" => command}} when is_binary(command) -> command
      {:ok, %{"path" => path}} when is_binary(path) -> path
      _ -> preview
    end
  end

  # Stops the run and says why; a run this process cannot stop is left for
  # the session's close to stop, and the one-shot ends now.
  defp stop_run(state, run_id, why) do
    id = elem(State.next_id(state.ui, :request), 0)
    {state, effects} = update(state, {:invoke, {:run_control, :stop, run_id}, id})

    if Enum.any?(effects, &match?({:command, %Request{request_id: ^id}}, &1)),
      do: say(%{state | stopped?: true}, why <> " was stopped."),
      else: finish(state, 1, why <> " cannot continue; open swarmcode to answer it.")
  end

  # -- the end ----------------------------------------------------------------

  defp maybe_settle(%{phase: :running} = state) do
    runs = Enum.map(state.runs, &Map.get(state.ui.read_model.runs, &1))

    if Enum.all?(runs, &(&1 != nil and &1.state in @terminal)) do
      query_completion(state)
    else
      state
    end
  end

  defp maybe_settle(state), do: state

  # The run's last state and its whole answer are read once more after it
  # ends: a non-streaming provider's answer and a long answer's rest arrive
  # only here, as a preview plus a detail reference.
  defp query_completion(state) do
    watch = state.ui.watches.workspace

    own_query(%{state | phase: :settling}, :completion, fn id ->
      %Request{
        request_id: id,
        kind: {:query, :workspace, nil, :before, 200, 1_048_576},
        scope: watch.scope,
        generation: watch.generation,
        origin: {:query, :workspace},
        deadline: state.clock.() + 30_000,
        expected_response: :workspace_snapshot
      }
    end)
  end

  defp own_response(state, :completion, %DTO.WorkspaceSnapshot{state: :idle} = snapshot) do
    runs = Enum.filter(snapshot.runs, &(&1.id in state.runs))

    if length(runs) == length(state.runs) and Enum.all?(runs, &(&1.state in @terminal)) do
      items =
        Enum.filter(
          snapshot.transcript.items,
          &(&1.run_id in state.runs and &1.role == :assistant and &1.kind == :text and
              &1.id != &1.node_id)
        )

      state = print_answer(state, items)

      details =
        for item <- items,
            item.detail_ref != nil,
            byte_size(Map.get(state.texts, item.id, "")) < item.detail_ref.total_bytes,
            do: {item.id, item.detail_ref.id}

      next_detail(%{state | details: details, phase: :fetching}, runs)
    else
      %{state | phase: :running}
    end
  end

  defp own_response(state, :completion, _), do: conclude(state, run_summaries(state))

  defp own_response(state, {:detail, id, ref, runs}, %DTO.DetailWindow{state: :idle} = window) do
    state = write_answer(state, id, window.text)

    if window.next_offset,
      do: query_detail(state, id, ref, window.next_offset, runs),
      else: next_detail(state, runs)
  end

  defp own_response(state, {:detail, _, _, runs}, _) do
    next_detail(say(state, "the rest of the answer could not be read."), runs)
  end

  defp next_detail(%{details: []} = state, runs), do: conclude(state, runs)

  defp next_detail(%{details: [{id, ref} | rest]} = state, runs),
    do:
      query_detail(
        %{state | details: rest},
        id,
        ref,
        byte_size(Map.get(state.texts, id, "")),
        runs
      )

  defp query_detail(state, id, ref, offset, runs) do
    watch = state.ui.watches.workspace

    own_query(state, {:detail, id, ref, runs}, fn request_id ->
      %Request{
        request_id: request_id,
        kind: {:query_detail, ref, offset, @detail_page},
        scope: watch.scope,
        generation: watch.generation,
        origin: {:query, :detail},
        deadline: state.clock.() + 30_000,
        expected_response: :detail_window
      }
    end)
  end

  defp own_query(state, purpose, build) do
    sequence = state.sequence + 1
    id = "one-shot-" <> Integer.to_string(sequence)
    request = build.(id)

    with {:ok, request} <- Request.validate(request),
         :ok <- safely(fn -> DataSource.query(state.client, request) end) do
      Process.send_after(self(), {:own_deadline, id}, @own_deadline_ms)
      %{state | sequence: sequence, own: Map.put(state.own, id, purpose)}
    else
      _ -> conclude(%{state | sequence: sequence}, run_summaries(state))
    end
  end

  defp run_summaries(state),
    do: Enum.flat_map(state.runs, &List.wrap(Map.get(state.ui.read_model.runs, &1)))

  defp conclude(state, runs) do
    failed = Enum.find(runs, &(&1.state != :done))

    cond do
      runs == [] ->
        finish(state, 1, "the run did not start.")

      failed == nil ->
        finish(state, 0)

      # The line saying why was written when this process stopped it.
      state.stopped? and failed.state == :stopped ->
        finish(state, 1)

      true ->
        finish(state, 1, run_words(failed))
    end
  end

  defp run_words(%DTO.RunSummary{state: :failed, error: error}) when is_binary(error),
    do: "the run failed: " <> first_line(error)

  defp run_words(%DTO.RunSummary{state: :failed}), do: "the run failed."
  defp run_words(%DTO.RunSummary{state: :stopped}), do: "the run was stopped."
  defp run_words(%DTO.RunSummary{state: :interrupted}), do: "the run was interrupted."
  defp run_words(%DTO.RunSummary{state: state}), do: "the run ended #{state}."

  defp finish(state, code, message \\ nil)
  defp finish(%{phase: :finished} = state, _, _), do: state

  defp finish(state, code, message) do
    state = if message, do: say(state, message), else: state

    case state.format do
      :json ->
        write(state.output, [Jason.encode!(summary(state, code, message)), "\n"])

      :text ->
        if state.mid_line?, do: write(state.output, "\n")
    end

    safely(fn -> DataSource.close(state.client) end)
    if state.observer, do: send(state.observer, {:one_shot, self(), {:finished, code}})
    %{state | phase: :finished, mid_line?: false}
  end

  defp summary(state, code, message) do
    run = state.runs |> List.first() |> then(&(&1 && Map.get(state.ui.read_model.runs, &1)))

    text =
      state.answer_order
      |> Enum.map(&Map.get(state.texts, &1, ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{
      "conversation_id" => state.conversation,
      "run_id" => List.first(state.runs),
      "state" => if(run, do: Atom.to_string(run.state), else: "not_started"),
      "text" => clean(text),
      "error" => message,
      "question" => state.question,
      "denied" => Enum.map(state.denied, &%{"tool" => &1.tool, "command" => &1.command}),
      "exit_code" => code
    }
  end

  # -- plumbing ---------------------------------------------------------------

  defp update(state, action) do
    ui = %{state.ui | now: state.clock.()}
    {ui, effects} = Reducer.update(ui, action)
    state = %{state | ui: ui}
    run_effects(state, effects)
    {state, effects}
  end

  defp run_effects(state, effects) do
    context = %{
      data_source: state.client,
      owner: self(),
      source_epoch: state.epoch,
      # Timers, copies and terminal controls belong to a screen; there is none.
      local: fn _ -> :ok end
    }

    Enum.each(effects, &EffectRunner.run(&1, context))
  end

  # A line for the person watching: on `error`, starting on a fresh line
  # when the answer stopped mid-line (the answer itself is not changed).
  defp say(state, text, prefix? \\ true) do
    lead = if state.fresh_line?, do: "", else: "\n"
    write(state.error, [lead, if(prefix?, do: "swarmcode: ", else: ""), clean(text), "\n"])
    %{state | fresh_line?: true}
  end

  defp write(device, iodata) do
    IO.write(device, iodata)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Terminal control characters never reach the terminal from a model:
  # everything but tab and newline below 0x20, DEL, and the C1 range.
  defp clean(text), do: String.replace(text, ~r/[\x00-\x08\x0B-\x1F\x7F\x{80}-\x{9F}]/u, "")

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 200)
  end

  defp outcome_words(%DTO.Outcome{error: %{message: message}}) when is_binary(message),
    do: message

  defp outcome_words(%DTO.Outcome{status: status}),
    do: status |> Atom.to_string() |> String.replace("_", " ")

  defp safely(fun) do
    fun.()
  catch
    _, _ -> {:error, :unavailable}
  end
end
