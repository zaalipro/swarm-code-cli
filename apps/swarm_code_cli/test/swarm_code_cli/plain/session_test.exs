defmodule SwarmCodeCLI.Plain.SessionTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.Demo.FiniteInput
  alias SwarmCodeCLI.Plain.{Options, Session}
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Source}

  test "session owns input, delivers question, resolves once and detaches without stopping runs" do
    fixture = File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__))
    {:ok, script} = Script.decode(fixture)
    source = start_supervised!({Source, script: script, source_epoch: "plain-epoch"})

    client =
      start_supervised!(
        {Fake, source: source, source_epoch: "plain-epoch", client_id: "plain-client"}
      )

    input = start_supervised!(FiniteInput)
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")

    session =
      start_supervised!(
        {Session,
         options: %Options{},
         data_source: client,
         input: input,
         output: output,
         error: error,
         source_epoch: "plain-epoch",
         observer: self(),
         conversation_id: Script.id(:a),
         now: Script.clock_ms()}
      )

    assert_receive {:plain_session, ^session, :ready}, 2000
    assert :ok = Source.advance(source, "a1-a2-b1-step-1")

    await_event(session, fn event ->
      match?({:delivery, %{body: %{kind: :interaction_upsert}}}, event)
    end)

    assert :ok = FiniteInput.release_line(input, "answer #{Script.id(:q1)}@7 option-2\n")

    await_event(session, fn event ->
      match?({:delivery, %{kind: :response, body: %{status: :accepted}}}, event)
    end)

    assert Source.snapshot(source).interactions[Script.id(:q1)].state == :resolved
    before_detach = Source.snapshot(source)
    assert :ok = FiniteInput.release_line(input, "detach\n")
    assert_receive {:plain_session, ^session, {:closed, :detach}}, 2000
    assert Source.snapshot(source) == before_detach
    {_, text} = StringIO.contents(output)
    assert text =~ "FAKE DEMO"
    assert text =~ "QUESTION"
    assert text =~ "accepted"
    refute text =~ "\e"
    assert StringIO.contents(error) == {"", ""}
    assert Session.snapshot(session).phase == :closed
  end

  test "piped EOF waits for an admitted command outcome before detaching" do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "plain-epoch"})

    client =
      start_supervised!(
        {Fake, source: source, source_epoch: "plain-epoch", client_id: "plain-client"}
      )

    input = start_supervised!(FiniteInput)
    {:ok, output} = StringIO.open("")

    session =
      start_supervised!(
        {Session,
         options: %Options{},
         data_source: client,
         input: input,
         output: output,
         error: output,
         source_epoch: "plain-epoch",
         observer: self(),
         conversation_id: Script.id(:a),
         now: Script.clock_ms()}
      )

    assert_receive {:plain_session, ^session, :ready}, 2000
    :sys.suspend(source)

    try do
      :ok = FiniteInput.release_line(input, "send -- \"preserved prompt\"\n")
      assert_receive {:plain_session, ^session, {:command, _}}, 2000
      assert Session.snapshot(session).phase == :awaiting_outcome
      :ok = FiniteInput.eof(input)
    after
      :sys.resume(source)
    end

    await_event(session, &match?({:delivery, %{kind: :response, body: %{status: :accepted}}}, &1))
    assert_receive {:plain_session, ^session, {:closed, :eof}}, 2000

    assert Enum.any?(Source.snapshot(source).transcript, fn {_, item} ->
             item.text == "preserved prompt"
           end)
  end

  test "finite input refuses additional buffered lines and oversize content" do
    input = start_supervised!(FiniteInput)
    assert :ok = FiniteInput.release_line(input, "first\n")
    assert {:error, :busy} = FiniteInput.release_line(input, "second\n")
    assert :ok = FiniteInput.eof(input)
    assert {:error, :closed} = FiniteInput.release_line(input, "later\n")
  end

  test "startup catalogue allows A to B to A and recovery settles its request before reading buffered input" do
    {source, client, input, session, output} = start_session()
    assert_receive {:plain_session, ^session, :ready}, 2000
    assert Map.has_key?(Session.snapshot(session).presenter.conversations, Script.id(:b))
    :ok = FiniteInput.release_line(input, "go conversation #{Script.id(:b)}\n")
    b = Script.id(:b)
    await_event(session, &match?({:delivery, %{kind: :watch_ready, scope: %{id: ^b}}}, &1))
    assert Session.snapshot(session).scope.id == Script.id(:b)
    :ok = FiniteInput.release_line(input, "go conversation #{Script.id(:a)}\n")
    a = Script.id(:a)
    await_event(session, &match?({:delivery, %{kind: :watch_ready, scope: %{id: ^a}}}, &1))

    :sys.suspend(client)
    :ok = Source.advance(source, "sequence-gap")
    :sys.suspend(source)
    :sys.resume(client)

    try do
      await_event(session, &match?({:delivery, %{kind: :resyncing}}, &1))
      assert Session.snapshot(session).phase == :awaiting_ready
      :ok = FiniteInput.release_line(input, "send -- buffered\n")
    after
      :sys.resume(source)
    end

    await_event(session, &match?({:delivery, %{kind: :response, body: %{status: :accepted}}}, &1))
    state = Session.snapshot(session)
    assert state.phase == :ready
    assert state.requests == %{}

    assert Enum.count(Source.snapshot(source).transcript, fn {_, item} ->
             item.text == "buffered"
           end) == 1

    :ok = Session.close(session, :interrupt)
    assert_receive {:plain_session, ^session, {:closed, :interrupt}}, 2000
    assert elem(StringIO.contents(output), 1) =~ "RESYNCING"
  end

  test "output device loss closes and detaches cleanly" do
    {_source, _client, input, session, output} = start_session()
    assert_receive {:plain_session, ^session, :ready}, 2000
    assert {:ok, _} = StringIO.close(output)
    :ok = FiniteInput.release_line(input, "help\n")
    assert_receive {:plain_session, ^session, {:closed, :output_failed}}, 2000
    assert Session.snapshot(session).phase == :closed
  end

  test "inspect tab survives parsing into the displayed snapshot" do
    {_source, _client, input, session, output} = start_session()
    assert_receive {:plain_session, ^session, :ready}, 2000
    :ok = FiniteInput.release_line(input, "inspect #{Script.id(:a1)} agents\n")
    await_event(session, &match?({:delivery, %{kind: :watch_ready, scope: %{kind: :run}}}, &1))
    assert Session.snapshot(session).presenter.inspector_tab == :agents
    assert elem(StringIO.contents(output), 1) =~ "INSPECTOR agents"
  end

  test "wrong typed response cannot settle a pending command" do
    {source, _client, input, session, _output} = start_session()
    assert_receive {:plain_session, ^session, :ready}, 2000
    :sys.suspend(source)

    try do
      :ok = FiniteInput.release_line(input, "send -- exact\n")
      assert_receive {:plain_session, ^session, {:command, request}}, 2000

      forged = %SwarmCodeCLI.UI.DataSource.Delivery{
        kind: :response,
        watch_ref: nil,
        request_id: request.request_id,
        scope: request.scope,
        generation: request.generation,
        revision: nil,
        sequence: nil,
        body: %SwarmCodeCLI.UI.DataSource.DTO.TranscriptWindow{request_id: request.request_id}
      }

      assert {:ok, _} = SwarmCodeCLI.UI.DataSource.Delivery.validate(forged)
      send(session, {:swarm_code_ui_data, "plain-epoch", forged})
      assert Session.snapshot(session).phase == :awaiting_outcome
      assert Map.has_key?(Session.snapshot(session).requests, request.request_id)
    after
      :sys.resume(source)
    end

    await_event(session, &match?({:delivery, %{kind: :response, body: %{status: :accepted}}}, &1))
    assert Session.snapshot(session).requests == %{}
  end

  test "unresponsive output is bounded and detaches its client" do
    test = self()

    device =
      spawn(fn ->
        receive do
          {:io_request, _, _, _} -> send(test, :output_started)
        end

        receive do
          :done -> :ok
        end
      end)

    on_exit(fn -> Process.exit(device, :kill) end)

    {_source, client, _input, session, _output} =
      start_session(nil, output: device, error: device, output_timeout: 20)

    assert_receive :output_started
    assert_receive {:plain_session, ^session, {:closed, :output_failed}}, 2000
    assert Session.snapshot(session).phase == :closed
    assert :sys.get_state(client).phase == :closed
  end

  test "reader handles charlist devices, drains oversized physical lines and dies with its owner" do
    # The ordinary Erlang IO protocol may return Unicode charlists.
    path = Path.join(System.tmp_dir!(), "plain-reader-#{System.unique_integer([:positive])}")
    File.write!(path, "héllo\n")
    {:ok, input} = :file.open(String.to_charlist(path), [:read, {:encoding, :utf8}])

    on_exit(fn ->
      :file.close(input)
      File.rm(path)
    end)

    {reader, monitor} = SwarmCodeCLI.Plain.LineReader.start(self(), input)
    send(reader, :read_next)
    assert_receive {:plain_input, ^reader, {:line, "héllo\n"}}, 2000
    send(reader, :read_next)
    assert_receive {:plain_input, ^reader, :eof}, 2000
    assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}, 2000

    {:ok, large} = StringIO.open(String.duplicate("a", 16_385) <> "\nnext\n")
    {reader, monitor} = SwarmCodeCLI.Plain.LineReader.start(self(), large)
    send(reader, :read_next)
    assert_receive {:plain_input, ^reader, {:error, :line_too_large}}, 2000
    send(reader, :read_next)
    assert_receive {:plain_input, ^reader, {:line, "next\n"}}, 2000
    send(reader, :read_next)
    assert_receive {:plain_input, ^reader, :eof}, 2000
    assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}, 2000

    device = start_supervised!(FiniteInput)
    test = self()

    owner =
      spawn(fn ->
        {reader, _} = SwarmCodeCLI.Plain.LineReader.start(self(), device)
        send(test, {:owned_reader, reader})
        send(reader, :read_next)

        receive do
          :wait -> :ok
        end
      end)

    assert_receive {:owned_reader, reader}
    monitor = Process.monitor(reader)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}, 2000
  end

  test "bounded detail commands reconstruct canonical text and retry typed query failures" do
    {:ok, initial} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    text = String.duplicate("😀é", 12_000)

    request = %SwarmCodeCLI.UI.DataSource.Request{
      request_id: "large",
      kind: {:dispatch, :send, text, :main, []},
      origin: {:draft, {Script.id(:a), :main}},
      scope: %SwarmCode.Protocol.Scope{kind: :conversation, id: Script.id(:a), generation: 0},
      generation: 0,
      deadline: Script.clock_ms() + 1000,
      expected_response: :outcome
    }

    {:ok, script, _, _} = Script.command(initial, request)
    {source, _client, input, session, output} = start_session(script)
    assert_receive {:plain_session, ^session, :ready}, 2000
    [ref] = Map.values(Session.snapshot(session).presenter.detail_refs)
    :ok = FiniteInput.release_line(input, "detail #{ref.id}\n")

    await_event(
      session,
      &match?(
        {:delivery,
         %{kind: :response, body: %SwarmCodeCLI.UI.DataSource.DTO.DetailWindow{state: :idle}}},
        &1
      )
    )

    first = Session.snapshot(session).detail
    assert first.next_offset > 0
    assert first.offset == 0

    # Force a real typed source deadline error, then retry the same offset.
    :sys.suspend(source)

    try do
      :ok = FiniteInput.release_line(input, "detail next\n")
      await_event(session, &match?({:query, _}, &1))
      await_event(session, &match?({:delivery, %{kind: :response, body: %{state: :error}}}, &1))
      assert Session.snapshot(session).detail.state == :error
    after
      :sys.resume(source)
    end

    :ok = FiniteInput.release_line(input, "detail retry\n")
    await_event(session, &match?({:delivery, %{kind: :response, body: %{state: :idle}}}, &1))
    complete_detail(input, session)
    :ok = Session.close(session, :detach)
    records = elem(StringIO.contents(output), 1) |> String.split("\n")

    chunks =
      for "DETAIL " <> record <- records,
          parts = String.split(record, " ", parts: 3),
          [_, _, content] <- [parts],
          do: content

    assert Enum.join(chunks) == text
  end

  defp complete_detail(input, session) do
    if Session.snapshot(session).detail.next_offset do
      :ok = FiniteInput.release_line(input, "detail next\n")
      await_event(session, &match?({:delivery, %{kind: :response, body: %{state: :idle}}}, &1))
      complete_detail(input, session)
    end
  end

  defp start_session(script \\ nil, overrides \\ []) do
    script =
      script ||
        elem(
          Script.decode(
            File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__))
          ),
          1
        )

    source = start_supervised!({Source, script: script, source_epoch: "plain-epoch"})

    client =
      start_supervised!(
        {Fake, source: source, source_epoch: "plain-epoch", client_id: "plain-client"}
      )

    input = start_supervised!(FiniteInput)
    {:ok, output} = StringIO.open("")

    opts =
      Keyword.merge(
        [
          options: %Options{},
          data_source: client,
          input: input,
          output: output,
          error: output,
          source_epoch: "plain-epoch",
          observer: self(),
          conversation_id: Script.id(:a),
          now: Script.clock_ms()
        ],
        overrides
      )

    session = start_supervised!({Session, opts})
    {source, client, input, session, output}
  end

  defp await_event(session, predicate) do
    receive do
      {:plain_session, ^session, event} ->
        if predicate.(event), do: :ok, else: await_event(session, predicate)
    after
      2000 -> flunk("missing serialized session event")
    end
  end
end
