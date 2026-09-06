defmodule SwarmCodeCLI.Plain.PresenterTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.Plain.{Presenter, Options, Command}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery, Delta}
  alias SwarmCode.Protocol.Scope
  @scope %Scope{kind: :conversation, id: "c", generation: 0}
  defp run,
    do: %DTO.RunSummary{
      id: "r",
      conversation_id: "c",
      title: "Café\e]0;bad\a",
      state: :waiting_question,
      revision: 4,
      allowed_actions: [:stop, :inspect]
    }

  defp prompt,
    do: %DTO.PendingInteraction{
      id: "q",
      run_id: "r",
      node_id: "n",
      conversation_id: "c",
      expected_revision: 7,
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        prompt: "Choose 東京",
        options: [%DTO.QuestionOption{id: "o", label: "Yes"}]
      }
    }

  defp delivery(body, sequence \\ nil) do
    %Delivery{
      kind: if(sequence, do: :delta, else: :watch_ready),
      watch_ref: "w",
      request_id: nil,
      scope: @scope,
      generation: 0,
      revision: if(sequence, do: body.revision, else: 1),
      sequence: sequence,
      body: body
    }
  end

  defp ready do
    %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      runs: [run()],
      transcript: %DTO.TranscriptWindow{},
      interactions: [prompt()],
      allowed_actions: [:send, :queue],
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }
  end

  defp output(records), do: records |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()

  test "foreground navigation hides offscope prompts without claiming settlement" do
    {p, _} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery(ready()))
    scope = %Scope{kind: :conversation, id: "other", generation: 1}
    p = Presenter.focus_scope(p, scope)

    d = %{
      delivery(%{ready() | conversation_id: "other", runs: [], interactions: []})
      | scope: scope,
        generation: 1,
        watch_ref: "other"
    }

    {p, records} = Presenter.present(p, "epoch", d)
    refute output(records) =~ "SETTLED"
    assert p.current_prompt == nil
    assert p.scope == scope
  end

  test "Inspector tabs select admitted records and state the missing changes surface" do
    item = %DTO.TranscriptItem{
      id: "i",
      run_id: "r",
      conversation_id: "c",
      node_id: "n",
      attempt_id: "a",
      text: "timeline entry"
    }

    agent = %DTO.AgentSummary{
      id: "agent",
      run_id: "r",
      revision: 9,
      state: :running,
      allowed_actions: [:stop_agent]
    }

    body = %DTO.RunDetailSnapshot{
      run: run(),
      agents: [agent],
      transcript: %DTO.TranscriptWindow{items: [item]}
    }

    for tab <- [:overview, :agents, :timeline, :changes] do
      p = Presenter.inspector_tab(Presenter.new(%Options{}), tab)
      {p, records} = Presenter.present(p, "epoch", delivery(body))
      text = output(records)
      assert text =~ "INSPECTOR #{tab}"
      assert Map.has_key?(p.agents, {"r", "agent"})
      assert text =~ "AGENT r/agent@9" == tab in [:overview, :agents]
      assert text =~ "timeline entry" == tab in [:overview, :timeline]
      if tab == :changes, do: assert(text =~ "unavailable")
    end
  end

  test "typed snapshot is append-only sanitized Unicode and deduplicated" do
    snapshot = delivery(ready())
    assert {:ok, _} = Delivery.validate(snapshot)
    {p, records} = Presenter.present(Presenter.new(%Options{ascii?: true}), "epoch", snapshot)
    text = output(records)
    assert text =~ "Café"
    assert text =~ "東京"
    refute text =~ "\e"
    refute text =~ "\a"
    assert length(Regex.scan(~r/answer q@7 o/, text)) == 1
    assert {^p, []} = Presenter.present(p, "epoch", snapshot)

    assert {:ok, {:intent, {:answer_question, "r", "n", "q", 7, ["o"]}}} =
             Command.parse("1", p, @scope)

    assert {:ok, {:intent, {:run_control, :stop, "r"}}} = Command.parse("stop r", p, @scope)
  end

  test "async output repeats the current prompt exactly once and settlement invalidates it" do
    {p, _} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery(ready()))

    delta = %Delta{
      kind: :stream_append,
      entity_id: "n",
      run_id: "r",
      conversation_id: "c",
      channel: :text,
      attempt_id: "attempt",
      text: "later",
      sequence: 1,
      revision: 2
    }

    {p, records} = Presenter.present(p, "epoch", delivery(delta, 1))
    assert length(Regex.scan(~r/answer q@7 o/, output(records))) == 1
    assert {^p, []} = Presenter.present(p, "epoch", delivery(delta, 1))

    settled = %Delta{
      kind: :interaction_remove,
      entity_id: "q",
      run_id: "r",
      conversation_id: "c",
      sequence: 2,
      revision: 3
    }

    {p, records} = Presenter.present(p, "epoch", delivery(settled, 2))
    assert output(records) == "SETTLED q\n"
    assert p.current_prompt == nil
    assert {:error, _} = Command.parse("answer q@7 o", p, @scope)
  end

  test "resync preserves facts and prompt but gates requests until fresh snapshot" do
    {p, _} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery(ready()))

    event = %Delivery{
      kind: :resyncing,
      watch_ref: "w",
      request_id: nil,
      scope: @scope,
      generation: 0,
      revision: nil,
      sequence: nil,
      body: nil
    }

    {resyncing, records} = Presenter.present(p, "epoch", event)
    assert resyncing.interactions == p.interactions
    assert output(records) == "RESYNCING\n"
    assert {:error, _} = Command.parse("answer q@7 o", resyncing, @scope)
    {fresh, records} = Presenter.present(resyncing, "epoch", delivery(ready()))
    assert fresh.status == :ready
    assert length(Regex.scan(~r/answer q@7 o/, output(records))) == 1
  end

  test "nonaccepted outcomes preserve domain registry and never display internal errors" do
    {p, _} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery(ready()))

    for status <- [
          :accepted,
          :needs_input,
          :rejected,
          :deadline_exceeded,
          :interrupted,
          :revision_conflict,
          :outcome_unknown
        ] do
      outcome = %DTO.Outcome{
        request_id: "request",
        status: status,
        interaction: if(status == :needs_input, do: prompt()),
        error:
          if(status == :rejected, do: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:not_allowed))
      }

      response = %Delivery{
        kind: :response,
        watch_ref: nil,
        request_id: "request",
        scope: @scope,
        generation: 0,
        revision: nil,
        sequence: nil,
        body: outcome
      }

      {next, records} = Presenter.present(p, "epoch", response)
      assert next.runs == p.runs
      assert next.interactions == p.interactions
      assert output(records) =~ Atom.to_string(status)
    end
  end

  test "all maximum-sized fields survive a bounded page and detail previews are explicit" do
    item = %DTO.TranscriptItem{
      id: "n",
      node_id: "n",
      run_id: "r",
      conversation_id: "c",
      attempt_id: "attempt",
      text: String.duplicate("x", 65_536),
      detail_ref: %DTO.DetailRef{id: "detail-1", total_bytes: 100_000}
    }

    items = for n <- 1..5, do: %{item | id: "n#{n}", node_id: "n#{n}"}
    snapshot = delivery(%DTO.TranscriptWindow{items: items})
    assert {:ok, _} = Delivery.validate(snapshot)
    {p, records} = Presenter.present(Presenter.new(%Options{}), "epoch", snapshot)
    text = output(records)
    assert length(Regex.scan(~r/preview; detail detail-1; total 100000 bytes/, text)) == 5
    assert length(Regex.scan(~r/x/, text)) == 5 * 65_536
    assert p.detail_refs["detail-1"].total_bytes == 100_000
    refute text =~ "limit"
  end

  test "distinct watches may carry identical projected sequence numbers" do
    {p, _} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery(ready()))

    delta = %Delta{
      kind: :stream_append,
      entity_id: "n",
      run_id: "r",
      conversation_id: "c",
      channel: :text,
      attempt_id: "attempt",
      text: "one",
      sequence: 1,
      revision: 2
    }

    {p, one} = Presenter.present(p, "epoch", delivery(delta, 1))
    {_, two} = Presenter.present(p, "epoch", %{delivery(delta, 1) | watch_ref: "inspector"})
    assert output(one) =~ "one"
    assert output(two) =~ "one"
  end

  test "another snapshot settles absent prompts and bare ambiguity prints a complete safe command" do
    second = %{prompt() | id: "q2"}

    {p, _} =
      Presenter.present(
        Presenter.new(%Options{}),
        "epoch",
        delivery(%{ready() | interactions: [prompt(), second]})
      )

    assert {:error, error} = Command.parse("1", p, @scope)
    assert SwarmCodeCLI.UI.SafeText.value(error) =~ "answer q@7 o"

    {p, records} =
      Presenter.present(p, "epoch", %{delivery(%{ready() | interactions: [second]}) | revision: 2})

    assert output(records) =~ "SETTLED q@7"
    assert p.current_prompt.id == "q2"

    assert {:ok, {:intent, {:answer_question, "r", "n", "q2", 7, ["o"]}}} =
             Command.parse("1", p, @scope)
  end

  test "color motion and ASCII options preserve semantic Unicode output" do
    outputs =
      for ascii <- [false, true],
          color <- [false, true],
          reduced <- [false, true],
          width <- [:narrow, :wide] do
        {_, records} =
          Presenter.present(
            Presenter.new(%Options{
              ascii?: ascii,
              color?: color,
              reduced_motion?: reduced,
              ambiguous_width: width
            }),
            "epoch",
            delivery(ready())
          )

        output(records)
      end

    assert length(Enum.uniq(outputs)) == 1
  end

  test "activity removal invalidates its associated prompt without reissuing it" do
    {p, _} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery(ready()))

    activity = %DTO.ActivityItem{
      id: "activity-q",
      run_id: "r",
      conversation_id: "c",
      kind: :question,
      state: :waiting_question,
      revision: 8,
      interaction: prompt()
    }

    upsert = %Delta{
      kind: :activity_upsert,
      entity_id: activity.id,
      run_id: "r",
      conversation_id: "c",
      body: activity,
      sequence: 1,
      revision: 8
    }

    {p, _} = Presenter.present(p, "epoch", delivery(upsert, 1))
    assert {:ok, _} = Command.parse("answer q@7 o", p, @scope)

    remove = %Delta{
      kind: :activity_remove,
      entity_id: activity.id,
      run_id: "r",
      conversation_id: "c",
      sequence: 2,
      revision: 9
    }

    {p, records} = Presenter.present(p, "epoch", delivery(remove, 2))
    assert p.current_prompt == nil
    refute Map.has_key?(p.interactions, "q")
    refute Map.has_key?(p.activities, activity.id)
    assert output(records) =~ "SETTLED q@7"
    refute output(records) =~ "QUESTION"
    assert {:error, _} = Command.parse("answer q@7 o", p, @scope)
  end

  test "run agent and activity records expose exact revision references" do
    run = %{run() | state: :failed, revision: 41, allowed_actions: [:retry]}

    agent = %DTO.AgentSummary{
      id: "agent",
      run_id: "r",
      revision: 42,
      state: :running,
      allowed_actions: [:stop_agent]
    }

    snapshot = %DTO.RunDetailSnapshot{
      run: run,
      agents: [agent],
      transcript: %DTO.TranscriptWindow{}
    }

    {p, records} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery(snapshot))
    assert output(records) =~ "RUN r@41 failed"
    assert output(records) =~ "AGENT r/agent@42 running"

    activity = %DTO.ActivityItem{
      id: "activity-r",
      run_id: "r",
      conversation_id: "c",
      kind: :failure,
      state: :failed,
      revision: 43,
      allowed_actions: [:mark_seen]
    }

    delta = %Delta{
      kind: :activity_upsert,
      entity_id: activity.id,
      run_id: "r",
      conversation_id: "c",
      body: activity,
      sequence: 1,
      revision: 43
    }

    {p, records} = Presenter.present(p, "epoch", delivery(delta, 1))
    assert output(records) =~ "ACTIVITY activity-r@43 failed"
    assert {:ok, _} = Command.parse("retry r@41", p, @scope)
    assert {:ok, _} = Command.parse("stop-agent r agent@42", p, @scope)
    assert {:ok, _} = Command.parse("seen activity activity-r@43", p, @scope)
  end

  test "reasoning is preserved distinctly in snapshots and append/reset streams" do
    node = %DTO.TranscriptItem{
      id: "n",
      node_id: "n",
      run_id: "r",
      conversation_id: "c",
      attempt_id: "attempt",
      text: "Answer",
      reasoning: "Why 東京\e[31m"
    }

    {p, records} =
      Presenter.present(
        Presenter.new(%Options{}),
        "epoch",
        delivery(%DTO.TranscriptWindow{items: [node]})
      )

    assert output(records) =~ "TEXT r/n Answer"
    assert output(records) =~ "REASONING r/n Why 東京"
    refute output(records) =~ "\e"

    for {kind, channel, heading, sequence} <- [
          {:stream_append, :text, "TEXT", 1},
          {:stream_append, :reasoning, "REASONING", 2},
          {:stream_reset, :text, "RESET TEXT", 3},
          {:stream_reset, :reasoning, "RESET REASONING", 4}
        ] do
      delta = %Delta{
        kind: kind,
        entity_id: "n",
        run_id: "r",
        conversation_id: "c",
        channel: channel,
        attempt_id: "attempt",
        text: "More",
        sequence: sequence,
        revision: sequence
      }

      {_, records} = Presenter.present(p, "epoch", delivery(delta, sequence))
      assert output(records) == heading <> " r/n More\n"
    end
  end

  test "removing an old activity does not settle a newer revision of its prompt" do
    {p, _} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery(ready()))

    activity = %DTO.ActivityItem{
      id: "activity-q",
      run_id: "r",
      conversation_id: "c",
      kind: :question,
      state: :waiting_question,
      revision: 8,
      interaction: prompt()
    }

    upsert = %Delta{
      kind: :activity_upsert,
      entity_id: activity.id,
      run_id: "r",
      conversation_id: "c",
      body: activity,
      sequence: 1,
      revision: 8
    }

    {p, _} = Presenter.present(p, "epoch", delivery(upsert, 1))
    newer = %{prompt() | expected_revision: 8}

    update = %Delta{
      kind: :interaction_upsert,
      entity_id: newer.id,
      run_id: "r",
      conversation_id: "c",
      body: newer,
      sequence: 2,
      revision: 9
    }

    {p, _} = Presenter.present(p, "epoch", delivery(update, 2))

    remove = %Delta{
      kind: :activity_remove,
      entity_id: activity.id,
      run_id: "r",
      conversation_id: "c",
      sequence: 3,
      revision: 10
    }

    {p, records} = Presenter.present(p, "epoch", delivery(remove, 3))
    assert p.current_prompt.expected_revision == 8
    assert output(records) =~ "SETTLED q@7"
    assert output(records) =~ "answer q@8 o"
    assert {:ok, _} = Command.parse("answer q@8 o", p, @scope)
  end

  test "Activity replacement rebuilds prompts and distinguishes covered removal from off-window omission" do
    scope = %Scope{kind: :global, id: nil, generation: 0}

    activity = %DTO.ActivityItem{
      id: "activity-q",
      run_id: "r",
      conversation_id: "c",
      kind: :question,
      state: :waiting_question,
      revision: 7,
      interaction: prompt()
    }

    initial = %{
      delivery(%DTO.ActivitySnapshot{items: [activity], counts: %DTO.Counts{}})
      | scope: scope
    }

    {p, _} = Presenter.present(Presenter.new(%Options{}), "epoch", initial)

    for presence <- [:covered, :off_window] do
      resync = %Delivery{
        kind: :resyncing,
        watch_ref: "w",
        request_id: nil,
        scope: scope,
        generation: 0,
        revision: nil,
        sequence: nil,
        body: nil
      }

      {syncing, _} = Presenter.present(p, "epoch", resync)

      replacement = %{
        initial
        | revision: 2,
          body: %DTO.ActivitySnapshot{items: [], counts: %DTO.Counts{}, presence: presence}
      }

      {current, records} = Presenter.present(syncing, "epoch", replacement)
      assert current.interactions == %{}
      assert current.current_prompt == nil
      assert {:error, _} = Command.parse("answer q@7 o", current, scope)
      assert output(records) =~ "SETTLED q@7" == (presence == :covered)
    end
  end

  test "fresh Activity questions resolve from exact item state without a cached RunSummary" do
    scope = %Scope{kind: :global, id: nil, generation: 0}

    activity = %DTO.ActivityItem{
      id: "activity-q",
      run_id: "r",
      conversation_id: "c",
      kind: :question,
      state: :waiting_question,
      revision: 7,
      interaction: prompt()
    }

    snapshot = %{
      delivery(%DTO.ActivitySnapshot{items: [activity], counts: %DTO.Counts{}})
      | scope: scope
    }

    {p, records} = Presenter.present(Presenter.new(%Options{}), "epoch", snapshot)
    assert p.runs == %{}
    assert output(records) =~ "answer q@7 o"
    assert {:ok, {:intent, intent}} = Command.parse("answer q@7 o", p, scope)
    assert {:ok, context} = Presenter.context(p, intent, scope)
    assert context.active_run_state == :waiting_question
    assert context.allowed_actions == [:answer_question]
    assert {:ok, _} = SwarmCodeCLI.UI.RequestResolver.resolve(intent, context, "request", 100)
    wrong = put_in(p.activities[activity.id].state, :running)
    assert {:error, _} = Command.parse("answer q@7 o", wrong, scope)
    wrong = put_in(p.activities[activity.id].run_id, "other")
    assert {:error, _} = Command.parse("answer q@7 o", wrong, scope)
    cached = %{p | runs: %{"r" => %{run() | state: :running}}}
    assert {:error, _} = Command.parse("answer q@7 o", cached, scope)
    stale = put_in(p.activities[activity.id].interaction.expected_revision, 6)
    assert {:error, _} = Command.parse("answer q@7 o", stale, scope)

    approval = %{
      prompt()
      | id: "approval",
        kind: :approval,
        question: nil,
        allowed_actions: [:approve]
    }

    item = %{
      activity
      | id: "activity-approval",
        kind: :approval,
        state: :waiting_approval,
        interaction: approval
    }

    {approval_presenter, _} =
      Presenter.present(Presenter.new(%Options{}), "epoch", %{
        snapshot
        | body: %DTO.ActivitySnapshot{items: [item], counts: %DTO.Counts{}}
      })

    assert {:ok, {:intent, {:resolve_approval, "r", "n", "approval", 7, :approve}}} =
             Command.parse("approve approval@7", approval_presenter, scope)

    assert {:error, _} = Command.parse("always-allow approval@7", approval_presenter, scope)
  end

  test "actual fake run Steer authority works independently of read-only node actions" do
    alias SwarmCodeCLI.UI.DataSource.Fake.Script

    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    run = script.runs[Script.id(:a1)]
    node = script.transcript["message-A-1"]
    assert :steer in run.allowed_actions
    refute :steer in node.allowed_actions
    scope = %Scope{kind: :conversation, id: run.conversation_id, generation: 0}

    snapshot = %DTO.WorkspaceSnapshot{
      conversation_id: run.conversation_id,
      runs: [run],
      transcript: %DTO.TranscriptWindow{items: [node]},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

    {p, _} =
      Presenter.present(Presenter.new(%Options{}), "epoch", %{delivery(snapshot) | scope: scope})

    line = "steer " <> run.id <> " " <> node.node_id <> " -- focus tests"
    assert {:ok, {:intent, intent}} = Command.parse(line, p, scope)
    assert {:ok, context} = Presenter.context(p, intent, scope)

    assert context.allowed_actions ==
             Enum.filter(run.allowed_actions, &SwarmCodeCLI.UI.Intent.permission?/1)

    assert {:ok, request} =
             SwarmCodeCLI.UI.RequestResolver.resolve(
               intent,
               context,
               "request",
               Script.clock_ms() + 30_000
             )

    assert {:ok, _, %{status: :accepted}, _} = Script.command(script, request)
    missing = put_in(p.runs[run.id].allowed_actions, [:stop])
    assert {:error, _} = Command.parse(line, missing, scope)
    superseded = put_in(p.nodes[{run.id, node.node_id}].state, :superseded)
    assert {:error, _} = Command.parse(line, superseded, scope)
  end

  test "inspecting one run cannot authorize commands for a retained sibling run" do
    first = %{run() | state: :running, allowed_actions: [:stop]}
    second = %{first | id: "sibling"}

    {p, _} =
      Presenter.present(
        Presenter.new(%Options{}),
        "epoch",
        delivery(%{ready() | runs: [first, second], interactions: []})
      )

    scope = %Scope{kind: :run, id: first.id, generation: 1}
    focused = Presenter.focus_scope(p, scope)

    detail = %{
      delivery(%DTO.RunDetailSnapshot{run: first, transcript: %DTO.TranscriptWindow{}})
      | scope: scope,
        generation: 1
    }

    {p, _} = Presenter.present(focused, "epoch", detail)
    assert Map.has_key?(p.runs, "sibling")
    assert {:error, _} = Command.parse("stop sibling", p, scope)

    assert {:error, :invalid_context} =
             Presenter.context(p, {:run_control, :stop, "sibling"}, scope)

    assert {:ok, _} = Command.parse("stop r", p, scope)
    global = %Scope{kind: :global, id: nil, generation: 1}
    assert {:ok, _} = Command.parse("stop sibling", %{p | scope: global}, global)
  end

  test "every revisioned command checks the admitted subject scope before authorization" do
    alias SwarmCodeCLI.TestSupport.RequestConformance, as: Fixtures

    for row <- Fixtures.domain_rows(), row["name"] not in ["send", "queue"] do
      p = Fixtures.presenter(row)
      intent = Fixtures.intent(row)
      wrong_run = %Scope{kind: :run, id: "different-run", generation: p.generation}

      wrong_conversation = %Scope{
        kind: :conversation,
        id: "different-conversation",
        generation: p.generation
      }

      for scope <- [wrong_run, wrong_conversation] do
        scoped = %{p | scope: scope}
        assert {:error, :invalid_context} = Presenter.context(scoped, intent, scope)
        assert {:error, _} = Command.parse(row["line"], scoped, scope)
      end

      global = %Scope{kind: :global, id: nil, generation: p.generation}

      if row["name"] == "seen_conversation" do
        assert {:error, _} = Command.parse(row["line"], %{p | scope: global}, global)
      else
        assert {:ok, _} = Command.parse(row["line"], %{p | scope: global}, global), row["name"]
      end
    end
  end

  test "cached run and interaction conversation identities must agree" do
    {p, _} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery(ready()))
    forged = put_in(p.interactions["q"].conversation_id, "other")
    assert {:error, _} = Command.parse("answer q@7 o", forged, @scope)
    global = %Scope{kind: :global, id: nil, generation: 0}
    assert {:error, _} = Command.parse("answer q@7 o", %{forged | scope: global}, global)
  end
end
