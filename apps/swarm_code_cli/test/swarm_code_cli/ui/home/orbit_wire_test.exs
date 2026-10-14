defmodule SwarmCodeCLI.UI.Home.OrbitWireTest do
  @moduledoc """
  orbit U1: the client half of `home.overview`, `conversation.search` and the
  `home_stale` push (spec §3.1-§3.4): the DTOs decode Appendix C exactly, the
  request kinds are bounded, the codec's bodies carry exactly the contract's
  keys, and the Fake answers both kinds and pushes the invalidation to the
  shell watch alone.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.{Message, Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.EffectRunner
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO, Fake, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Session, Source}

  @fixture Path.expand("../../../fixtures/home/overview.json", __DIR__)
  @wire "11111111-1111-4111-8111-111111111111"
  @nonce String.duplicate("A", 43)
  @watch_ref "99999999-9999-4999-8999-999999999999"
  @global %Scope{kind: :global, id: nil, generation: 3}
  @now Script.clock_ms()

  defp appendix_c, do: @fixture |> File.read!() |> Jason.decode!()

  defp request(kind, origin, opts \\ []) do
    %Request{
      request_id: Keyword.get(opts, :request_id, "orbit-1"),
      kind: kind,
      scope: Keyword.get(opts, :scope, @global),
      generation: 3,
      origin: origin,
      deadline: @now + 100_000,
      expected_response:
        case kind do
          {:home_overview, _, _, _} -> :home_overview
          _ -> :conversation_list
        end
    }
  end

  describe "Appendix C" do
    test "decodes into the DTO tree, with a budget or without" do
      assert {:ok, %DTO.HomeOverview{} = body} = DTO.HomeOverview.decode(appendix_c())
      assert body.state == :ready and body.revision == 3 and body.request_id == "req-0001"

      assert [%DTO.HomeProject{current: true, conversations: [_ | _]} = here, other] =
               body.projects

      assert here.name == "swarm-code-cli" and here.conversation_count == 9
      assert [%DTO.HomeConversation{live: false, waiting: 1} | _] = here.conversations
      assert other.current == false and other.last_opened_at == nil

      assert %DTO.HomeMonth{spend_usd: 38.4, budget_usd: 60.0} = body.month

      assert %DTO.HomeScheduled{name: "nightly deps audit", next_run_at: 1_792_000_840_000} =
               body.next_scheduled

      assert [%DTO.HomeRun{kind: :swarm, progress: 60}, %DTO.HomeRun{kind: :research}] =
               body.live_runs

      no_budget = put_in(appendix_c(), ["month", "budget_usd"], nil)
      assert {:ok, %{month: %DTO.HomeMonth{budget_usd: nil}}} = DTO.HomeOverview.decode(no_budget)

      none = appendix_c() |> Map.put("month", nil) |> Map.put("next_scheduled", nil)
      assert {:ok, %{month: nil, next_scheduled: nil}} = DTO.HomeOverview.decode(none)
    end

    test "a whole-number budget decodes as a float" do
      wire = put_in(appendix_c(), ["month", "budget_usd"], 60)
      assert {:ok, %{month: %{budget_usd: 60.0}}} = DTO.HomeOverview.decode(wire)
    end

    test "an unknown key, a missing key and a bad enum are refused" do
      assert {:error, :invalid_dto} = DTO.HomeOverview.decode(Map.put(appendix_c(), "x", 1))
      assert {:error, :invalid_dto} = DTO.HomeOverview.decode(Map.delete(appendix_c(), "month"))

      bad_kind = put_in(appendix_c(), ["live_runs", Access.at(0), "kind"], "nope")
      assert {:error, :invalid_dto} = DTO.HomeOverview.decode(bad_kind)

      bad_progress = put_in(appendix_c(), ["live_runs", Access.at(0), "progress"], 101)
      assert {:error, :invalid_dto} = DTO.HomeOverview.decode(bad_progress)
    end

    test "the lists are bounded as on the wire" do
      run = hd(appendix_c()["live_runs"])
      six = Map.put(appendix_c(), "live_runs", List.duplicate(run, 6))
      assert {:error, :invalid_dto} = DTO.HomeOverview.decode(six)

      project = hd(appendix_c()["projects"])
      nine = Map.put(appendix_c(), "projects", List.duplicate(project, 9))
      assert {:error, :invalid_dto} = DTO.HomeOverview.decode(nine)

      bead = hd(project["conversations"])

      many =
        put_in(
          appendix_c(),
          ["projects", Access.at(0), "conversations"],
          List.duplicate(bead, 25)
        )

      assert {:error, :invalid_dto} = DTO.HomeOverview.decode(many)
    end

    test "an error body needs its request id" do
      error = %DTO.HomeOverview{
        request_id: "r",
        state: :error,
        error: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:closed)
      }

      assert {:ok, _} = DTO.HomeOverview.validate(error)
      assert {:error, :invalid_dto} = DTO.HomeOverview.validate(%{error | request_id: nil})
      assert {:error, :invalid_dto} = DTO.HomeOverview.validate(%{error | error: nil})
    end

    test "the home_stale body is one revision" do
      assert {:ok, %DTO.HomeStale{revision: 8}} = DTO.HomeStale.decode(%{"revision" => 8})
      assert {:error, :invalid_dto} = DTO.HomeStale.decode(%{"revision" => -1})
      assert {:error, :invalid_dto} = DTO.HomeStale.decode(%{})
    end
  end

  describe "request kinds" do
    test "the constants Home sends are valid, with their origins" do
      assert {:ok, _} =
               Request.validate(request({:home_overview, 6, 12, 131_072}, {:home, :overview}))

      assert {:ok, _} =
               Request.validate(
                 request({:conversation_search, "rate limit", 50, 262_144}, {:home, :search})
               )
    end

    test "out-of-range parameters are refused" do
      overview = {:home, :overview}

      for kind <- [
            {:home_overview, 0, 12, 1},
            {:home_overview, 9, 12, 1},
            {:home_overview, 6, 0, 1},
            {:home_overview, 6, 25, 1},
            {:home_overview, 6, 12, 0},
            {:home_overview, 6, 12, 1_048_577}
          ] do
        assert {:error, :invalid_request} = Request.validate(request(kind, overview))
      end

      search = {:home, :search}

      for kind <- [
            {:conversation_search, "", 50, 1},
            {:conversation_search, String.duplicate("a", 201), 50, 1},
            {:conversation_search, "ok", 51, 1},
            {:conversation_search, "ok", 0, 1},
            {:conversation_search, "ok", 50, 0},
            {:conversation_search, "line\nbreak", 50, 1},
            {:conversation_search, <<255, 254>>, 50, 1}
          ] do
        assert {:error, :invalid_request} = Request.validate(request(kind, search))
      end

      assert {:ok, _} =
               Request.validate(
                 request({:conversation_search, String.duplicate("é", 100), 50, 1}, search)
               )
    end

    test "a mismatched origin or response kind is refused" do
      assert {:error, :invalid_request} =
               Request.validate(request({:home_overview, 6, 12, 131_072}, {:home, :search}))

      assert {:error, :invalid_request} =
               Request.validate(request({:conversation_search, "x", 50, 1}, {:home, :overview}))

      assert {:error, :invalid_request} =
               Request.validate(request({:home_overview, 6, 12, 1}, {:conversation, :list}))

      wrong = %{
        request({:home_overview, 6, 12, 1}, {:home, :overview})
        | expected_response: :outcome
      }

      assert {:error, :invalid_request} = Request.validate(wrong)
    end
  end

  describe "the codec" do
    test "each kind's body has exactly the contract's keys" do
      assert {:ok, overview} = Codec.wire_body({:home_overview, 6, 12, 131_072})

      assert overview == %{
               "op" => "home.overview",
               "projects" => 6,
               "per_project" => 12,
               "byte_limit" => 131_072
             }

      assert {:ok, search} = Codec.wire_body({:conversation_search, "rate limit", 50, 262_144})

      assert search == %{
               "op" => "conversation.search",
               "query" => "rate limit",
               "limit" => 50,
               "byte_limit" => 262_144
             }
    end

    test "the whole request is built once the core knows the ops" do
      # Lane S adds the two ops to `ServiceRequest`; before that merge the core
      # refuses them and the codec keeps its `invalid_request` answer.
      {:ok, wire} = Codec.wire_body({:home_overview, 6, 12, 131_072})

      core_knows? =
        match?({:ok, _}, ServiceRequest.decode(Map.put(wire, "timeout_ms", 5000), @global))

      kind = request({:home_overview, 6, 12, 131_072}, {:home, :overview})

      if core_knows? do
        assert {:ok, %Message{body: %{"op" => "home.overview", "timeout_ms" => 5000}}} =
                 Codec.request(kind, @wire, @nonce, @now + 5_000)
      else
        assert {:error, %{code: :invalid_request}} =
                 Codec.request(kind, @wire, @nonce, @now + 5_000)
      end
    end

    defp result(kind, value),
      do: %Message{
        version: 1,
        sequence: nil,
        occurred_at: nil,
        type: :response,
        request_id: @wire,
        nonce: @nonce,
        scope: @global,
        body: %{"op" => "result", "response_kind" => kind, "value" => value}
      }

    test "a home_overview reply becomes a typed delivery with the local request id" do
      value = Map.put(appendix_c(), "request_id", @wire)
      kind = request({:home_overview, 6, 12, 131_072}, {:home, :overview})

      assert {:ok, %Delivery{kind: :response, request_id: "orbit-1", body: body}} =
               Codec.response(result("home_overview", value), kind, @wire, @nonce)

      assert %DTO.HomeOverview{request_id: "orbit-1", state: :ready} = body
    end

    test "a reply of another kind, or with another shape, is refused" do
      value = Map.put(appendix_c(), "request_id", @wire)
      kind = request({:home_overview, 6, 12, 131_072}, {:home, :overview})

      assert {:error, %{code: :invalid_request}} =
               Codec.response(result("conversation_list", value), kind, @wire, @nonce)

      assert {:error, %{code: :invalid_request}} =
               Codec.response(
                 result("home_overview", Map.put(value, "extra", 1)),
                 kind,
                 @wire,
                 @nonce
               )

      assert {:error, %{code: :invalid_request}} =
               Codec.response(
                 result("home_overview", Map.put(value, "request_id", "someone-else")),
                 kind,
                 @wire,
                 @nonce
               )
    end

    defp shell_watch,
      do: %Watch{
        watch_ref: @watch_ref,
        slot: :shell,
        scope: @global,
        generation: 3,
        page_size: 20,
        byte_limit: 262_144
      }

    defp stale_event(revision, body_revision) do
      %Message{
        version: 1,
        type: :event,
        request_id: nil,
        nonce: @nonce,
        scope: @global,
        sequence: 4,
        occurred_at: "2026-10-14T00:00:00Z",
        body: %{
          "op" => "delta",
          "watch_ref" => @watch_ref,
          "value" => %{
            "kind" => "home_stale",
            "entity_id" => nil,
            "run_id" => nil,
            "conversation_id" => nil,
            "channel" => nil,
            "attempt_id" => nil,
            "text" => nil,
            "body" => %{"revision" => body_revision},
            "sequence" => 4,
            "revision" => revision
          }
        }
      }
    end

    test "a home_stale delta is accepted though its revision is not the watch's" do
      # The body names the backend's home revision (8), the envelope the watch's (21).
      assert {:ok, %Delivery{kind: :delta, body: %Delta{kind: :home_stale, body: body}}} =
               Codec.event(stale_event(21, 8), shell_watch(), @nonce)

      assert body == %DTO.HomeStale{revision: 8}
    end
  end

  describe "ReadModel" do
    test "keeps the newest home revision" do
      model = %SwarmCodeCLI.UI.ReadModel{}

      stale = fn n ->
        %Delta{kind: :home_stale, body: %DTO.HomeStale{revision: n}, sequence: 1, revision: 1}
      end

      assert {:ok, model, [], []} = SwarmCodeCLI.UI.ReadModel.delta(model, :shell, stale.(5))
      assert model.home_revision == 5
      assert {:ok, model, [], []} = SwarmCodeCLI.UI.ReadModel.delta(model, :shell, stale.(3))
      assert model.home_revision == 5

      assert {:ok, %{home_revision: 9}, [], []} =
               SwarmCodeCLI.UI.ReadModel.delta(model, :shell, stale.(9))
    end
  end

  describe "the Fake" do
    defp script do
      {:ok, value} =
        Script.decode(
          File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
        )

      value
    end

    defp bound(script) do
      source = start_supervised!({Source, script: script, source_epoch: "epoch"}, id: make_ref())

      client =
        start_supervised!({Fake, source: source, source_epoch: "epoch", client_id: "client"},
          id: make_ref()
        )

      {:ok, _} = Fake.bind_owner(client, self(), "binding")
      :ok = Fake.watch(client, shell_watch())
      assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :watch_ready}}, 2_000
      {source, client}
    end

    defp ask(client, %Request{} = request) do
      :ok = Fake.query(client, request)
      id = request.request_id

      assert_receive {:swarm_code_ui_data, "epoch",
                      %Delivery{kind: :response, request_id: ^id, body: body}},
                     2_000

      body
    end

    test "answers home.overview from the script, current project first" do
      {_source, client} = bound(script())
      kind = request({:home_overview, 6, 12, 131_072}, {:home, :overview})
      assert %DTO.HomeOverview{state: :ready} = body = ask(client, kind)

      assert [%DTO.HomeProject{current: true, name: "swarm-code"} = here] = body.projects
      assert body.project_id == here.id
      assert here.conversation_count == length(here.conversations)
      assert Enum.all?(here.conversations, &match?(%DTO.HomeConversation{}, &1))
      assert body.month == %DTO.HomeMonth{spend_usd: 0.0, budget_usd: nil}
      assert length(body.live_runs) in 1..5
      assert Enum.all?(body.live_runs, &(&1.project_id == here.id))
    end

    test "serves the scripted extra projects, month and schedule" do
      {:ok, wire} = DTO.HomeOverview.decode(appendix_c())
      [_here, other] = wire.projects

      extra = %{
        projects: [other],
        month: wire.month,
        next_scheduled: wire.next_scheduled,
        waiting_total: 1
      }

      script = script()
      script = %{script | session: %{script.session | home: extra}}
      assert {:ok, _} = Script.validate(script)

      {_source, client} = bound(script)
      body = ask(client, request({:home_overview, 6, 12, 131_072}, {:home, :overview}))
      assert [%{current: true}, %{current: false, name: "llmotions"}] = body.projects
      assert body.month.budget_usd == 60.0
      assert body.next_scheduled.name == "nightly deps audit"
      assert body.waiting_total == 1

      narrow = request({:home_overview, 1, 1, 131_072}, {:home, :overview}, request_id: "orbit-2")
      one = ask(client, narrow)
      assert [%{current: true, conversations: [_]}] = one.projects
    end

    test "answers conversation.search by title or prompt, case-insensitively" do
      {_source, client} = bound(script())
      [first | _] = Map.values(script().session.conversations)
      needle = String.upcase(String.slice(first.title, 0, 5))

      kind = request({:conversation_search, needle, 50, 262_144}, {:home, :search})

      assert %DTO.ConversationList{items: items, before_cursor: nil, after_cursor: nil} =
               ask(client, kind)

      assert first.id in Enum.map(items, & &1.id)

      none = request({:conversation_search, "zzzz-no-such-text", 50, 262_144}, {:home, :search})
      assert %DTO.ConversationList{items: []} = ask(client, %{none | request_id: "orbit-3"})
    end

    test "the overview names the revision the source holds, so it is not asked for again" do
      {source, client} = bound(script())
      :ok = Source.home_stale(source, 7)
      assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :delta}}, 2_000

      kind = request({:home_overview, 6, 12, 1_048_576}, {:home, :overview})
      assert %DTO.HomeOverview{revision: 7} = ask(client, kind)
    end

    test "home_stale reaches the shell watch and no other" do
      {source, client} = bound(script())
      other_ref = "88888888-8888-4888-8888-888888888888"

      conversation = %Watch{
        watch_ref: other_ref,
        slot: :workspace,
        scope: %Scope{kind: :conversation, id: Script.id(:a), generation: 0},
        generation: 0,
        page_size: 20,
        byte_limit: 1_048_576
      }

      :ok = Fake.watch(client, conversation)

      assert_receive {:swarm_code_ui_data, "epoch",
                      %Delivery{kind: :watch_ready, watch_ref: ^other_ref}},
                     2_000

      :ok = Source.home_stale(source, 3)

      assert_receive {:swarm_code_ui_data, "epoch",
                      %Delivery{
                        kind: :delta,
                        watch_ref: @watch_ref,
                        body: %Delta{kind: :home_stale, body: %DTO.HomeStale{revision: 3}}
                      }},
                     2_000

      refute_receive {:swarm_code_ui_data, "epoch",
                      %Delivery{watch_ref: ^other_ref, kind: :delta}},
                     100
    end

    test "an admission failure for home_overview yields an error body" do
      {_source, client} = bound(script())
      Fake.close(client)

      context = %{
        data_source: client,
        owner: self(),
        source_epoch: "epoch",
        local: fn _ -> flunk("unexpected local effect") end
      }

      kind = request({:home_overview, 6, 12, 131_072}, {:home, :overview}, request_id: "orbit-9")
      assert :ok = EffectRunner.run({:query, kind}, context)

      assert_receive {:swarm_code_ui_data, "epoch",
                      %Delivery{kind: :response, request_id: "orbit-9", body: body} = delivery}

      assert {:ok, _} = Delivery.validate(delivery)
      assert %DTO.HomeOverview{state: :error, request_id: "orbit-9"} = body
      assert {:ok, _} = DTO.HomeOverview.validate(body)
    end

    test "the Session fake keeps its fixtures valid" do
      assert Session.valid?(script().session)
    end
  end
end
