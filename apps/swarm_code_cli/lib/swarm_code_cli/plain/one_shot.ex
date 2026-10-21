defmodule SwarmCodeCLI.Plain.OneShot do
  @moduledoc """
  `ncode -p PROMPT`: one turn in the saved conversation with nobody at the
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

  A run the prompt's runs launch (a swarm or workflow a tool started, found
  through `parent_run_id`, transitively) is followed too: the session waits
  until every one of them has ended, names each on `error`, lists them under
  `runs` in the JSON summary, and exits `1` when any failed or was stopped.
  Nothing caps how many are followed: the set is what was launched. That
  includes the chat turn a finished workflow starts to report its result, and
  the compaction that turn waits for when the conversation asked for one (the
  domain records the workflow as the launcher of both). A finished workflow
  whose launch is still pending (`launch_pending?`: its process has not
  stopped, or a turn is chained onto a compaction on its behalf) may be about
  to start that turn, so the session does not conclude until the launch has
  happened and its run is followed. Nothing but that fact ends the wait: the
  domain bounds the hook the turn waits for and the compaction's chain, and a
  signal or a limit still ends the session.
  `--max-turns` applies to the lead of each followed run, `--max-budget-usd`
  to the cost of all of them together; a limit stops every live run, and one
  that is first heard of after the limit fired.

  A run that parks as `paused` (a workflow whose provider stayed down, or one
  paused by hand) does not end by itself here, because nothing resumes it. The
  session ends once nothing else is live, says why it paused and how to
  continue (`ncode --resume <id>`, then `/resume-run`), and exits `1`.
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

  alias SwarmCodeCLI.Release.Reasons
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{DataBridge, Delivery, DTO, Request}

  @terminal [:done, :failed, :stopped, :interrupted, :superseded]
  # Nothing more happens to a paused run without a person.
  @settled [:paused | @terminal]
  # How often a pending launch is asked about again.
  @recheck_ms 25
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
  optionally `format` (`:text` | `:json`), `output` and `error` (IO devices), `sink`
  (an arity-1 function that hears the turn's assistant text and reasoning as typed
  events, see `emit/2`),
  `progress` (tool lines on `error`), `clock` (a zero-arity millisecond clock),
  `launch_pending?` (`run_id -> boolean`: does the run still have a launch to
  make; none by default) and `recheck_ms` (how often that is asked again).
  """
  @spec run(keyword()) :: 0 | 1 | 129 | 143
  def run(options) do
    {:ok, pid} = GenServer.start(__MODULE__, Keyword.put(options, :observer, self()))
    monitor = Process.monitor(pid)
    await(pid, monitor)
  end

  defp await(pid, monitor) do
    receive do
      {:one_shot, ^pid, {:finished, code}} ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        code

      # cli020 B9: SIGTERM/SIGHUP reach the caller (the session owner); the
      # one-shot stops its run and finishes with the signal's code.
      {:shutdown_signal, signal} when signal in [:sigterm, :sighup] ->
        send(pid, {:shutdown_signal, signal})
        await(pid, monitor)

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
    images = Keyword.get(options, :images, [])
    output_file = Keyword.get(options, :output_file)

    if Intent.valid_id?(epoch) and Intent.valid_id?(conversation) and Intent.valid_text?(prompt) and
         format in [:text, :json, :stream_json] and valid_images?(images) and
         valid_output_file?(output_file) do
      client = Keyword.fetch!(options, :data_source)

      state = %{
        phase: :binding,
        client: client,
        client_monitor: Process.monitor(client),
        epoch: epoch,
        conversation: conversation,
        prompt: prompt,
        format: format,
        # pass 77 C-FEAT-10: `--image` files attached one by one before the
        # prompt (`attaching` is the one being attached), and `-o` the file the
        # final answer is also written to.
        images: images,
        attaching: nil,
        output_file: output_file,
        output: Keyword.get(options, :output, :standard_io),
        error: Keyword.get(options, :error, :standard_error),
        progress?: Keyword.get(options, :progress, false) == true,
        clock: Keyword.get(options, :clock, fn -> System.system_time(:millisecond) end),
        observer: Keyword.get(options, :observer),
        # Review 1019 RC-1/RC-2: a caller that wants the turn's typed events (`ncode acp`).
        sink: sink_option(Keyword.get(options, :sink)),
        sink_last: nil,
        thoughts: %{},
        # cli020 B3: `--fail-on-denied`, and the folder the hint names.
        fail_on_denied?: Keyword.get(options, :fail_on_denied, false) == true,
        project_root: Keyword.get(options, :project_root),
        # Tool items of the owned runs counted as blocked (by the policy or a hook).
        blocked: MapSet.new(),
        # cli020 B23: the run's limits, and the plain presenter whose records
        # `--output-format stream-json` writes, one JSON object per line.
        max_turns: Keyword.get(options, :max_turns),
        max_budget_usd: Keyword.get(options, :max_budget_usd),
        limited?: false,
        no_cost_said?: false,
        presenter:
          if(format == :stream_json,
            do: SwarmCodeCLI.Plain.Presenter.new(%SwarmCodeCLI.Plain.Options{format: :ndjson})
          ),
        ui: nil,
        dispatch: nil,
        runs: [],
        # Runs launched by `runs` (transitively), newest found first and never
        # capped, and the ids of both for membership tests.
        followed: [],
        known: MapSet.new(),
        # The runs a fired limit has asked to stop.
        stopping: MapSet.new(),
        # A finished workflow may still be starting its continuation.
        launch_pending?: Keyword.get(options, :launch_pending?, fn _ -> false end),
        recheck_ms: Keyword.get(options, :recheck_ms, @recheck_ms),
        launch_timer: nil,
        # The settled summaries of the tracked runs, once they are read, and
        # the sentence about the first that did not finish.
        final: [],
        error_text: nil,
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
        # pass76: the `Release.Reasons` word of the first thing that made this
        # process stop a run (a limit, a question, an approval nobody can answer).
        stop_reason: nil,
        announced: MapSet.new(),
        details: [],
        # pass 77 C-BUG-9: an own query (the completion read, a detail page)
        # is asked a second time once; `retried` names those asked again
        # (`:completion`, `{:detail, id, offset}`), and `incomplete?` is set
        # when one still did not answer: the exit is then 1, never a quiet 0
        # with half an answer.
        retried: MapSet.new(),
        incomplete?: false,
        sequence: 0
      }

      {:ok, state, {:continue, :bind}}
    else
      {:stop, :invalid_one_shot}
    end
  end

  @max_images 4

  defp valid_images?(images) do
    is_list(images) and length(images) <= @max_images and
      Enum.all?(images, &(is_binary(&1) and Intent.valid_text?("/attach " <> &1)))
  end

  defp valid_output_file?(nil), do: true

  defp valid_output_file?(file),
    do: is_binary(file) and file != "" and Path.type(file) == :absolute

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
        stop(
          finish_with(state, :session_unavailable, 1, "the saved session could not be opened.")
        )
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
      _ -> stop(finish_with(next, :session_unavailable, 1, "the session stopped answering."))
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
      do:
        stop(
          finish_with(state, :session_closed, 1, "the session closed before the run finished.")
        )

  def handle_info({:DOWN, monitor, :process, _, _}, %{client_monitor: monitor} = state),
    do:
      stop(finish_with(state, :session_closed, 1, "the session closed before the run finished."))

  # The source answers every request, if only with a failure; one that never
  # does must not keep the command waiting.
  def handle_info({:own_deadline, id}, %{own: own} = state) when is_map_key(own, id) do
    {purpose, own} = Map.pop(own, id)
    continue(own_response(%{state | own: own}, purpose, :deadline))
  end

  def handle_info({:timeout, timer, :launch_recheck}, %{launch_timer: timer} = state),
    do: continue(check(%{state | launch_timer: nil}))

  def handle_info({:shutdown_signal, signal}, %{phase: phase} = state)
      when signal in [:sigterm, :sighup] and phase != :finished do
    state = if state.ui, do: Enum.reduce(tracked(state), state, &signal_stop/2), else: state
    words = SwarmCodeCLI.Release.Signals.words(signal)
    stop(finish_with(state, signal, SwarmCodeCLI.Release.Signals.exit_code(signal), words))
  end

  def handle_info(_, state), do: {:noreply, state}

  # A live owned run is asked to stop; the session's close stops it anyway.
  defp signal_stop(run_id, state) do
    case Map.get(state.ui.read_model.runs, run_id) do
      %{state: run_state} when run_state in @terminal ->
        state

      _ ->
        id = elem(State.next_id(state.ui, :request), 0)
        {state, _effects} = update(state, {:invoke, {:run_control, :stop, run_id}, id})
        state
    end
  end

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
    state = stream_records(state, delivery)

    state
    |> observe_outcome(delivery)
    |> check()
  end

  # pass 77 C-FEAT-10: an `--image` was staged (an accepted `/attach` that
  # answers the staged attachment), or the prompt is not sent at all.
  defp observe_outcome(%{phase: :attaching, dispatch: id} = state, %Delivery{
         kind: :response,
         request_id: id,
         body: %DTO.Outcome{} = outcome
       })
       when is_binary(id) do
    case outcome do
      %{status: :accepted, result: %{kind: :attachment}} ->
        attach_next(state)

      _ ->
        finish_with(
          state,
          :prompt_not_sent,
          1,
          "the image " <>
            clean(state.attaching) <>
            " could not be attached (it must be a PNG, JPEG, GIF or WebP inside the project folder)."
        )
    end
  end

  defp observe_outcome(%{dispatch: id} = state, %Delivery{
         kind: :response,
         request_id: id,
         body: %DTO.Outcome{} = outcome
       })
       when is_binary(id) do
    case outcome do
      # pass 77 C-BUG-8: only an outcome that says it started or steered a run
      # is followed. Any other accepted answer (a `/rename`, a `/stop` with
      # nothing running, a queued prompt) names the conversation or nothing
      # and starts no run: it is the whole result.
      %{status: :accepted, disposition: disposition, identifiers: [_ | _] = ids}
      when disposition in [:started, :steered] ->
        runs = Enum.take(ids, 8)
        %{state | phase: :running, runs: runs, known: MapSet.new(runs)}

      %{status: :accepted} ->
        # A slash command answers at once and starts nothing.
        text = if outcome.feedback, do: outcome.feedback.text, else: ""
        finish(reconcile(state, "command", text), 0)

      _ ->
        finish_with(
          state,
          :prompt_not_sent,
          1,
          "the prompt was not sent: " <> outcome_words(outcome) <> "."
        )
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
      stop_run(
        state,
        interaction.run_id,
        "the approval could not be denied, so the run",
        :approval_required
      )
    end
  end

  defp observe_outcome(state, _), do: state

  defp check(%{phase: :opening} = state) do
    watch = state.ui.watches.workspace

    case {watch.status, Map.get(state.ui.read_model.snapshots, :workspace)} do
      {:ready, %DTO.WorkspaceSnapshot{conversation_id: id}} when id == state.conversation ->
        send_prompt(state)

      {:error, _} ->
        finish_with(state, :session_unavailable, 1, "the conversation could not be opened.")

      _ ->
        state
    end
  end

  defp check(%{phase: :running} = state) do
    state = follow(state, Map.values(state.ui.read_model.runs))

    state
    |> print_answer(answer_items(state))
    |> print_thoughts()
    |> announce_tools()
    |> count_blocked(ReadModel.items(state.ui.read_model, :workspace))
    |> answer_interactions()
    |> enforce_limits()
    |> maybe_settle()
  end

  defp check(state), do: state

  # -- cli020 B23: stream-json and the run's limits ---------------------------

  # The workspace watch's deliveries go through a plain presenter; each of
  # its records is one line `{"stream", "text"}` (the `--plain --ndjson`
  # shape), and `finish/3` ends the stream with `{"type": "summary", …}`.
  defp stream_records(%{presenter: nil} = state, _delivery), do: state

  defp stream_records(state, %Delivery{scope: scope} = delivery) do
    watch = state.ui && state.ui.watches.workspace

    if watch && scope == watch.scope do
      {presenter, records} =
        SwarmCodeCLI.Plain.Presenter.present(state.presenter, state.epoch, delivery)

      Enum.each(records, fn {stream, content} ->
        line = %{"stream" => Atom.to_string(stream), "text" => IO.iodata_to_binary(content)}
        write(state.output, [Jason.encode!(line), "\n"])
      end)

      %{state | presenter: presenter}
    else
      state
    end
  end

  defp enforce_limits(%{phase: :finished} = state), do: state

  # A fired limit stays fired: the update of a run launched before it can
  # arrive after the update that crossed it, and that run is stopped too.
  defp enforce_limits(%{limited?: true} = state) do
    case stop_live(state) do
      {state, []} -> state
      {state, [_ | _]} -> finish(state, 1, nil, state.stop_reason)
    end
  end

  # The turn limit looks at each live run's lead; the budget at what all the
  # tracked runs cost together, so a swarm a chat launched cannot spend past
  # it unseen. Either limit stops every live run.
  defp enforce_limits(state) do
    model = state.ui.read_model
    runs = Enum.flat_map(tracked(state), &List.wrap(Map.get(model.runs, &1)))
    live = Enum.reject(runs, &(&1.state in @terminal))
    cost = runs |> Enum.map(& &1.cost_usd) |> Enum.filter(&is_number/1) |> Enum.sum()

    cond do
      live == [] ->
        state

      Enum.any?(live, &turns_passed?(state, model, &1.id)) ->
        limit_stop(state, :max_turns, "stopped after #{state.max_turns} turns.")

      is_number(state.max_budget_usd) and cost > state.max_budget_usd ->
        subject = if length(runs) == 1, do: "the run", else: "the runs"

        limit_stop(
          state,
          :max_budget,
          "stopped at --max-budget-usd #{budget(state.max_budget_usd)} " <>
            "(#{subject} cost $#{:erlang.float_to_binary(cost * 1.0, decimals: 2)})."
        )

      true ->
        state
    end
  end

  defp turns_passed?(%{max_turns: max}, model, run_id) when is_integer(max) do
    Enum.any?(model.agents, fn {_id, agent} ->
      agent.run_id == run_id and agent.role == :lead and is_integer(agent.turn) and
        agent.turn > max
    end)
  end

  defp turns_passed?(_state, _model, _run_id), do: false

  defp budget(x) when is_float(x), do: x |> Float.to_string() |> String.trim_trailing(".0")
  defp budget(x), do: to_string(x)

  defp limit_stop(state, reason, words) do
    state = note_stop_reason(state, reason)
    {state, _unstoppable} = stop_live(state)
    sent? = MapSet.size(state.stopping) > 0

    state = say(%{state | limited?: true}, words)
    if sent?, do: %{state | stopped?: true}, else: finish_with(state, reason, 1)
  end

  # Asks every tracked run that is live and not yet asked to stop. Returns the
  # live ones that offer no stop to ask for.
  defp stop_live(state) do
    Enum.reduce(tracked(state), {state, []}, fn run_id, {state, unstoppable} ->
      if live_run?(state, run_id) and not MapSet.member?(state.stopping, run_id) do
        id = elem(State.next_id(state.ui, :request), 0)
        {state, effects} = update(state, {:invoke, {:run_control, :stop, run_id}, id})

        if Enum.any?(effects, &match?({:command, %Request{request_id: ^id}}, &1)),
          do: {%{state | stopping: MapSet.put(state.stopping, run_id)}, unstoppable},
          else: {state, [run_id | unstoppable]}
      else
        {state, unstoppable}
      end
    end)
  end

  # The first cause wins: it is what the summary's `reason` says when the
  # run then ends `stopped`.
  defp note_stop_reason(state, reason),
    do: %{state | stop_reason: state.stop_reason || Reasons.get(reason)}

  defp live_run?(state, run_id) do
    case Map.get(state.ui.read_model.runs, run_id) do
      %{state: run_state} -> run_state not in @terminal
      nil -> false
    end
  end

  # -- runs the prompt's runs launched ---------------------------------------

  # The prompt's runs, then the ones they launched, in the order found.
  defp tracked(state), do: state.runs ++ Enum.reverse(state.followed)

  # Adds the runs among `runs` that a tracked run launched, and those they
  # launched in turn, oldest first. None is left out: a run that is not
  # followed would be neither waited for nor reported, and the session's close
  # would stop it.
  defp follow(state, runs) do
    by_parent = Enum.group_by(runs, & &1.parent_run_id)
    follow_children(state, by_parent, MapSet.to_list(state.known))
  end

  defp follow_children(state, _by_parent, []), do: state

  defp follow_children(state, by_parent, parents) do
    fresh =
      parents
      |> Enum.flat_map(&Map.get(by_parent, &1, []))
      |> Enum.reject(&MapSet.member?(state.known, &1.id))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&{&1.created_sequence, &1.id})
      |> Enum.map(& &1.id)

    state = %{
      state
      | followed: Enum.reverse(fresh, state.followed),
        known: Enum.into(fresh, state.known)
    }

    follow_children(state, by_parent, fresh)
  end

  # A run whose cost stays unknown is never stopped by the budget; said once,
  # when the run has ended without one.
  defp say_no_cost(%{max_budget_usd: x, no_cost_said?: false} = state, runs) when is_number(x) do
    if Enum.any?(runs, &(&1.state in @terminal and &1.cost_usd == nil)),
      do:
        say(
          %{state | no_cost_said?: true},
          "the provider reports no cost; --max-budget-usd is not enforced."
        ),
      else: state
  end

  defp say_no_cost(state, _runs), do: state

  # -- sending ----------------------------------------------------------------

  # cli74: the settings layer needs the full-screen terminal; a one-shot
  # says so and sends nothing.
  defp send_prompt(%{prompt: prompt} = state) when is_binary(prompt) do
    if SwarmCodeCLI.UI.Keymap.settings_command?(prompt),
      do: finish_with(state, :prompt_not_sent, 1, SwarmCodeCLI.Plain.Command.settings_words()),
      else: attach_next(state)
  end

  # pass 77 C-FEAT-10: each `--image` goes out as `/attach <path>`, one at a
  # time, through the same dispatch the prompt takes; the backend stages it and
  # the prompt that follows consumes the staged images. A refused attach ends
  # the command before any prompt is sent.
  defp attach_next(%{images: [path | rest]} = state) do
    send_text(%{state | images: rest, attaching: path}, "/attach " <> path, :attaching)
  end

  defp attach_next(state), do: send_line(state)

  defp send_line(state), do: send_text(state, state.prompt, :sending)

  defp send_text(state, text, phase) do
    key = {state.conversation, :main}
    {state, _} = update(state, {:editor, key, {:paste, text}})
    text = Editor.text(Drafts.fetch(state.ui.drafts, key).editor)
    intent = {:dispatch, :send, text, :main, []}
    id = elem(State.next_id(state.ui, :request), 0)
    {state, effects} = update(state, {:invoke, intent, id})

    if Enum.any?(effects, &match?({:command, %Request{request_id: ^id}}, &1)) do
      %{state | phase: phase, dispatch: id}
    else
      finish_with(
        state,
        if(busy?(state), do: :conversation_busy, else: :prompt_not_sent),
        1,
        "the conversation cannot take a prompt right now" <> busy(state) <> "."
      )
    end
  end

  defp busy?(state), do: Keymap.live_turn(state.ui) != nil

  defp busy(state) do
    if busy?(state),
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
        MapSet.member?(state.known, item.run_id),
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
        state = emit(state, {:text_restart, id})
        state = say(state, "the answer restarted.")
        # The new attempt starts on a line of its own in the output too.
        if state.format == :text and state.mid_line?, do: write(state.output, "\n")
        state = %{state | texts: Map.put(state.texts, id, ""), mid_line?: false}
        write_answer(%{state | last_written: nil}, id, text)
    end
  end

  defp write_answer(state, _id, ""), do: state

  defp write_answer(state, id, chunk) do
    state = emit_text(state, id, chunk)
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

  # -- the typed events of the turn (review 1019 RC-1/RC-2) -------------------

  # The caller's `sink` (an arity-1 function, called in this process) hears the current
  # turn's assistant text and reasoning exactly as this process settles them, never the
  # transcript's older items or a user message (`answer_items/1` takes the assistant items
  # of the tracked runs only):
  #
  #   {:text, message_id, chunk}      the bytes appended to the answer, a "\n\n" first when it
  #                                   is a later message (the summary's `text` is their concatenation)
  #   {:text_restart, message_id}     the message's attempt restarted; its text starts again
  #   {:reasoning, message_id, chunk} the bytes appended to the message's reasoning
  #   {:reasoning_restart, message_id}
  #   {:summary, map}                 once, last: the summary object the format writes
  defp sink_option(sink) when is_function(sink, 1), do: sink
  defp sink_option(_other), do: nil

  defp emit(%{sink: nil} = state, _event), do: state

  defp emit(%{sink: sink} = state, event) do
    safely(fn -> sink.(event) end)
    state
  end

  defp emit_text(%{sink: nil} = state, _id, _chunk), do: state

  defp emit_text(state, id, chunk) do
    separator = if state.sink_last not in [nil, id], do: "\n\n", else: ""
    emit(%{state | sink_last: id}, {:text, id, separator <> chunk})
  end

  defp print_thoughts(%{sink: nil} = state), do: state

  defp print_thoughts(state),
    do: Enum.reduce(answer_items(state), state, &thought(&2, &1.id, &1.reasoning))

  defp thought(state, id, text) when is_binary(text) and text != "" do
    known = Map.get(state.thoughts, id, "")

    cond do
      text == known ->
        state

      String.starts_with?(text, known) ->
        chunk = binary_part(text, byte_size(known), byte_size(text) - byte_size(known))
        state |> emit({:reasoning, id, chunk}) |> put_thought(id, text)

      # A shorter text is the same reasoning cut to a preview.
      String.starts_with?(known, text) ->
        state

      true ->
        state
        |> emit({:reasoning_restart, id})
        |> emit({:reasoning, id, text})
        |> put_thought(id, text)
    end
  end

  defp thought(state, _id, _text), do: state

  defp put_thought(state, id, text), do: %{state | thoughts: Map.put(state.thoughts, id, text)}

  defp announce_tools(%{progress?: false} = state), do: state

  defp announce_tools(state) do
    model = state.ui.read_model

    Enum.reduce(ReadModel.items(model, :workspace), state, fn item, state ->
      if MapSet.member?(state.known, item.run_id) and item.kind == :tool and
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
      &(&1.state == :pending and MapSet.member?(state.known, &1.run_id) and
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
      "the run asked \"#{prompt}\" and nobody is here to answer, so it",
      :question_asked
    )
  end

  defp answer(%{phase: :running, denials: denials} = state, item) when denials >= @max_denials,
    do: stop_run(state, item.run_id, "#{@max_denials} approvals were denied, so the run", :denied)

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
        # cli020 B3: one line at the end names every denial (`denied_line/3`).
        %{
          state
          | answers: Map.put(state.answers, id, item),
            denials: state.denials + 1,
            denied: Enum.take(state.denied ++ [what], 32)
        }
      else
        stop_run(
          state,
          item.run_id,
          "#{what.label} could not be denied, so the run",
          :approval_required
        )
      end
    else
      stop_run(state, item.run_id, "#{what.label} needs a person, so the run", :approval_required)
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

  @doc """
  cli020 B3: the one stderr line a one-shot ends with when tool calls were
  denied (auto-denied approvals and calls the policy or a hook blocked): at
  most five labels, then how many more, then how to allow them.
  """
  @spec denied_line([String.t()], term(), String.t() | nil) :: String.t()
  def denied_line(labels, mode, root) do
    count = length(labels)
    shown = Enum.take(labels, 5)
    rest = count - length(shown)
    names = Enum.join(shown, ", ") <> if(rest > 0, do: " and #{rest} more", else: "")
    mode_name = if mode in [nil, ""], do: "unknown", else: to_string(mode)

    "#{count} tool call(s) were denied (approval mode #{mode_name}): #{names}." <>
      allow_hint(mode, root)
  end

  defp allow_hint(mode, root) when mode in [:read_only, "read_only"],
    do:
      " Allow them with: ncode config set project.approval_mode auto --project " <>
        shell_quote(root || ".") <> ", or answer them in ncode."

  defp allow_hint(mode, _root), do: denial_hint(mode)

  defp shell_quote(path) do
    if path =~ ~r/^[A-Za-z0-9_\/.~+-]+$/,
      do: path,
      else: "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  # cli020 B3: a tool call of an owned run that the policy or a hook refused
  # (`"blocked by …"`, `"hook blocked: …"`, from the op's error in the item's
  # text) counts as denied, once per item.
  defp count_blocked(state, items) do
    Enum.reduce(items, state, fn item, state ->
      if MapSet.member?(state.known, item.run_id) and item.kind == :tool and
           not MapSet.member?(state.blocked, item.id) and blocked?(item.text) do
        %{
          state
          | blocked: MapSet.put(state.blocked, item.id),
            denied: Enum.take(state.denied ++ [blocked_label(item)], 32)
        }
      else
        state
      end
    end)
  end

  defp blocked?(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.any?(
      &(String.starts_with?(&1, "blocked by ") or String.starts_with?(&1, "hook blocked: "))
    )
  end

  defp blocked?(_), do: false

  defp blocked_label(%{tool: %DTO.ToolCall{name: name, title: title}}) do
    subject = first_line(title || "")
    subject = if subject == name, do: "", else: subject
    label = String.trim(name <> " " <> subject)

    %{
      tool: name,
      command: if(subject == "", do: nil, else: subject),
      label: if(label == "", do: "a tool call", else: label)
    }
  end

  defp blocked_label(_), do: %{tool: nil, command: nil, label: "a tool call"}

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
  defp stop_run(state, run_id, why, reason) do
    state = note_stop_reason(state, reason)
    id = elem(State.next_id(state.ui, :request), 0)
    {state, effects} = update(state, {:invoke, {:run_control, :stop, run_id}, id})

    if Enum.any?(effects, &match?({:command, %Request{request_id: ^id}}, &1)),
      do: say(%{state | stopped?: true}, why <> " was stopped."),
      else: finish_with(state, reason, 1, why <> " cannot continue; open ncode to answer it.")
  end

  # -- the end ----------------------------------------------------------------

  defp maybe_settle(%{phase: :running} = state) do
    runs = Enum.map(tracked(state), &Map.get(state.ui.read_model.runs, &1))

    cond do
      not Enum.all?(runs, &(&1 != nil and &1.state in @settled)) -> state
      pending_launch?(state, runs) -> await_launch(state)
      true -> query_completion(state)
    end
  end

  defp maybe_settle(state), do: state

  # A row reads `done` before its run is over: a workflow's process starts the
  # continuation (a chat turn it is recorded as the launcher of) after that,
  # possibly after a hook has run, and possibly by handing it to a chain task
  # that waits for a compaction. Concluding on the rows would close the session
  # on a turn that does not exist yet, so an ended run is asked whether it still
  # has a launch to make. The answer is a fact of the run's own lifecycle, so
  # waiting for it needs no time limit, and it never turns back to true: once
  # it is false the launch's row exists, and a completion query sent after
  # that reads it. Only a workflow starts anything after its row is terminal;
  # a chat or swarm that lingers is the session close's to wait for.
  defp pending_launch?(state, runs) do
    Enum.any?(runs, fn run ->
      ended_workflow?(run) and match?(true, safely(fn -> state.launch_pending?.(run.id) end))
    end)
  end

  defp ended_workflow?(run), do: run.kind == :workflow and run.state in @terminal

  defp await_launch(%{launch_timer: nil, recheck_ms: ms} = state),
    do: %{state | launch_timer: :erlang.start_timer(ms, self(), :launch_recheck)}

  defp await_launch(state), do: state

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
    # The snapshot can show a run launched since the read model last heard.
    state = %{state | retried: MapSet.delete(state.retried, :completion)}
    known = state.known
    state = follow(state, snapshot.runs)
    ids = tracked(state)
    by_id = Map.new(snapshot.runs, &{&1.id, &1})
    model_runs = state.ui.read_model.runs

    # The snapshot holds the newest runs only; a followed run beyond it is
    # what the deltas last said (all tracked runs had settled to get here).
    runs = Enum.flat_map(ids, &List.wrap(by_id[&1] || model_runs[&1]))

    cond do
      length(runs) != length(ids) or not Enum.all?(runs, &(&1.state in @settled)) ->
        %{state | phase: :running}

      pending_launch?(state, runs) ->
        await_launch(%{state | phase: :running})

      # A workflow first seen here was not asked about before this snapshot
      # was read, and may have launched something since.
      Enum.any?(runs, &(ended_workflow?(&1) and not MapSet.member?(known, &1.id))) ->
        query_completion(%{state | phase: :running})

      true ->
        read_answers(state, snapshot, runs)
    end
  end

  # A failed or late completion read is asked once more; asked twice, the
  # answer is incomplete.
  defp own_response(state, :completion, _) do
    if MapSet.member?(state.retried, :completion),
      do: conclude(%{state | incomplete?: true}, run_summaries(state)),
      else: query_completion(%{state | retried: MapSet.put(state.retried, :completion)})
  end

  defp own_response(state, {:detail, id, ref, runs}, %DTO.DetailWindow{state: :idle} = window) do
    state = write_answer(state, id, window.text)

    if window.next_offset,
      do: query_detail(state, id, ref, window.next_offset, runs),
      else: next_detail(state, runs)
  end

  # The page that failed was not written, so the text so far ends at its offset.
  defp own_response(state, {:detail, id, ref, runs}, _) do
    offset = byte_size(Map.get(state.texts, id, ""))
    key = {:detail, id, offset}

    if MapSet.member?(state.retried, key) do
      state = say(%{state | incomplete?: true}, "the rest of the answer could not be read.")
      next_detail(state, runs)
    else
      query_detail(%{state | retried: MapSet.put(state.retried, key)}, id, ref, offset, runs)
    end
  end

  defp read_answers(state, snapshot, runs) do
    items =
      Enum.filter(
        snapshot.transcript.items,
        &(MapSet.member?(state.known, &1.run_id) and &1.role == :assistant and
            &1.kind == :text and &1.id != &1.node_id)
      )

    state =
      state
      |> print_answer(items)
      |> count_blocked(
        Enum.filter(snapshot.transcript.items, &MapSet.member?(state.known, &1.run_id))
      )

    details =
      for item <- items,
          item.detail_ref != nil,
          byte_size(Map.get(state.texts, item.id, "")) < item.detail_ref.total_bytes,
          do: {item.id, item.detail_ref.id}

    next_detail(%{state | details: details, phase: :fetching}, runs)
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
      _ -> conclude(%{state | sequence: sequence, incomplete?: true}, run_summaries(state))
    end
  end

  defp run_summaries(state),
    do: Enum.flat_map(tracked(state), &List.wrap(Map.get(state.ui.read_model.runs, &1)))

  defp conclude(state, runs) do
    state = say_no_cost(state, runs)
    state = %{state | final: runs}

    cond do
      runs == [] ->
        finish_with(state, :run_not_started, 1, "the run did not start.")

      Enum.all?(runs, &(&1.state == :done)) ->
        state = Enum.reduce(followed_runs(state, runs), state, &say(&2, run_words(state, &1)))

        cond do
          # pass 77 C-BUG-9: the runs are done, but part of the answer could
          # not be read (the partial text is already printed).
          state.incomplete? ->
            finish_with(
              state,
              :answer_incomplete,
              1,
              "the run finished, but its answer could not be read in full."
            )

          # cli020 B3: `--fail-on-denied` fails a done run that had denials.
          state.fail_on_denied? and state.denied != [] ->
            finish_with(state, :denied, 1)

          true ->
            finish(state, 0)
        end

      true ->
        # Every run that did not finish is named, in order, and so is every
        # launched run that did; the summary's `error` is the first line of a
        # run that did not. The line saying why this process stopped a run was
        # written when it did.
        entries =
          for run <- runs,
              not (run.state == :done and run.id in state.runs),
              not (state.stopped? and run.state == :stopped),
              do: {run.state, run_words(state, run)}

        state = Enum.reduce(entries, state, fn {_state, line}, state -> say(state, line) end)
        error = Enum.find_value(entries, fn {run_state, line} -> run_state != :done && line end)
        finish(%{state | error_text: error}, 1)
    end
  end

  defp followed_runs(state, runs), do: Enum.reject(runs, &(&1.id in state.runs))

  # What a run that ended (or parked) is called: the prompt's own run is "the
  # run", one it launched by its kind and title.
  defp run_words(state, %DTO.RunSummary{} = run) do
    subject =
      if run.id in state.runs,
        do: "the run",
        else: "the #{run.kind} \"#{String.slice(first_line(run.title || ""), 0, 60)}\""

    subject <> " " <> run_verb(state, run)
  end

  defp run_verb(_state, %DTO.RunSummary{state: :done}), do: "finished."

  defp run_verb(_state, %DTO.RunSummary{state: :failed, error: error}) when is_binary(error),
    do: "failed: " <> first_line(error)

  defp run_verb(_state, %DTO.RunSummary{state: :failed}), do: "failed."
  defp run_verb(_state, %DTO.RunSummary{state: :stopped}), do: "was stopped."
  defp run_verb(_state, %DTO.RunSummary{state: :interrupted}), do: "was interrupted."

  # Nothing here resumes a parked run: the sentence says why it paused and
  # how to carry on in ncode.
  defp run_verb(state, %DTO.RunSummary{state: :paused, error: error}) do
    why = if is_binary(error) and error != "", do: ": " <> first_line(error), else: ""

    "paused" <>
      String.trim_trailing(why, ".") <>
      ". ncode -p does not resume it; run `ncode --resume #{state.conversation}` " <>
      "and then /resume-run to continue."
  end

  defp run_verb(_state, %DTO.RunSummary{state: state}), do: "ended #{state}."

  # `reason` is a `Release.Reasons` word for a non-zero `code`; without one the
  # summary names the stop this process made, else the run that did not finish.
  defp finish(state, code, message \\ nil, reason \\ nil)
  defp finish(%{phase: :finished} = state, _, _, _), do: state

  defp finish(state, code, message, reason) do
    if state.launch_timer, do: :erlang.cancel_timer(state.launch_timer)
    {state, code, message, reason} = write_output_file(state, code, message, reason)
    state = if message, do: say(state, message), else: state

    state =
      if state.denied != [],
        do:
          say(
            state,
            denied_line(Enum.map(state.denied, & &1.label), mode(state), state.project_root)
          ),
        else: state

    message = message || state.error_text
    summary = summary(state, code, message, reason)
    # The last event of the turn, from this same process, so after every text event.
    state = emit(state, {:summary, summary})

    case state.format do
      :json ->
        write(state.output, [Jason.encode!(summary), "\n"])

      :stream_json ->
        write(state.output, [Jason.encode!(Map.put(summary, "type", "summary")), "\n"])

      :text ->
        if state.mid_line?, do: write(state.output, "\n")
    end

    safely(fn -> DataSource.close(state.client) end)
    if state.observer, do: send(state.observer, {:one_shot, self(), {:finished, code}})
    %{state | phase: :finished, mid_line?: false, launch_timer: nil}
  end

  defp finish_with(state, key, code, message \\ nil),
    do: finish(state, code, message, Reasons.get(key))

  # pass 77 C-FEAT-10: `-o FILE` also gets the final answer, the summary's
  # `text`, replaced atomically (a temporary file in the same folder, renamed).
  # Nothing is written for a command that failed with no answer at all, so an
  # earlier file is not emptied by a run that never started. A write that fails
  # is said on stderr and turns an exit 0 into 1 (`output_not_written`).
  defp write_output_file(%{output_file: nil} = state, code, message, reason),
    do: {state, code, message, reason}

  defp write_output_file(state, code, message, reason) do
    text = answer_text(state)

    with true <- code == 0 or text != "",
         {:error, why} <- atomic_write(state.output_file, text) do
      line = "could not write " <> clean(state.output_file) <> ": " <> clean(why)

      if code == 0,
        do: {state, 1, message || line, reason || Reasons.get(:output_not_written)},
        else: {say(state, line), code, message, reason}
    else
      _written_or_skipped -> {state, code, message, reason}
    end
  end

  defp atomic_write(file, text) do
    tmp = file <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false) <> ".tmp"

    try do
      File.write!(tmp, text, [:binary])
      File.rename!(tmp, file)
      :ok
    rescue
      error ->
        _ = File.rm(tmp)
        {:error, write_reason(error)}
    catch
      kind, reason ->
        _ = File.rm(tmp)
        {:error, inspect({kind, reason}, limit: 5)}
    end
  end

  defp write_reason(%File.Error{reason: reason}),
    do: reason |> :file.format_error() |> to_string()

  defp write_reason(%File.RenameError{reason: reason}),
    do: reason |> :file.format_error() |> to_string()

  defp write_reason(error), do: Exception.message(error)

  defp summary(state, code, message, reason) do
    runs = summary_runs(state)
    # The first run that did not finish speaks for the session; the first one
    # when all did.
    run = Enum.find(runs, &(&1.state != :done)) || List.first(runs)

    text = answer_text(state)

    %{
      "conversation_id" => state.conversation,
      "run_id" => List.first(state.runs),
      "state" => if(run, do: Atom.to_string(run.state), else: "not_started"),
      # pass76: why a non-zero exit happened, as a stable word (null when done).
      "reason" => summary_reason(state, code, run, reason),
      # cli020 B5: the exact text; Jason escapes what JSON must, and a
      # script decides what reaches a terminal.
      "text" => text,
      "error" => message,
      "question" => state.question,
      "denied" => Enum.map(state.denied, &%{"tool" => &1.tool, "command" => &1.command}),
      # Every run the session followed: the prompt's own, then the ones they
      # launched (a swarm, a workflow).
      "runs" => Enum.map(runs, &run_entry(state, &1)),
      "exit_code" => code
    }
  end

  # The answer as the summary and `-o` carry it: the assistant's messages in
  # order, as printed.
  defp answer_text(state) do
    state.answer_order
    |> Enum.map(&Map.get(state.texts, &1, ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp summary_reason(_state, 0, _run, _reason), do: nil
  defp summary_reason(_state, _code, _run, reason) when is_binary(reason), do: reason
  defp summary_reason(state, _code, run, nil), do: Reasons.for_run(run, state.stop_reason)

  defp summary_runs(%{final: [_ | _] = final}), do: final
  defp summary_runs(state), do: run_summaries(state)

  defp run_entry(state, run) do
    %{
      "id" => run.id,
      "kind" => Atom.to_string(run.kind),
      "state" => Atom.to_string(run.state),
      "title" => String.slice(first_line(run.title || ""), 0, 120),
      "parent_run_id" => run.parent_run_id,
      "launched" => run.id not in state.runs,
      "error" => run.error
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
    write(state.error, [lead, if(prefix?, do: "ncode: ", else: ""), clean(text), "\n"])
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
