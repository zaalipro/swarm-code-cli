defmodule SwarmCodeCLI.UI.DataSource.C74SettingsCodecTest do
  @moduledoc """
  pass74 S1-6: the client side of the settings wire — requests bounded by the one
  `WireBounds` function, the two response kinds decoded with the §3.4.6 rules
  (a bad secret shape refuses the whole answer without closing the connection,
  an invalid scalar only marks itself), the `outcome` reply mapped to a
  `SettingsResult`, the two global deltas, and `Fake.Settings`.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias SwarmCode.Protocol.{Message, Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.{Effect, EffectRunner}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Delta, DTO, Fake, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Source}
  alias SwarmCodeCLI.TestSupport.{ContractFixtures, RequestConformance}

  @wire "11111111-1111-4111-8111-111111111111"
  @nonce String.duplicate("A", 43)
  @global %Scope{kind: :global, id: nil, generation: 3}
  @provider "0d5e0000-0000-4000-8000-000000000001"
  @canary "sk-canary-0000000000000000c4n4"
  @watch_ref "99999999-9999-4999-8999-999999999999"

  defp result_message(kind, value, scope \\ @global),
    do: %Message{
      version: 1,
      sequence: nil,
      occurred_at: nil,
      type: :response,
      request_id: @wire,
      nonce: @nonce,
      scope: scope,
      body: %{"op" => "result", "response_kind" => kind, "value" => value}
    }

  defp query(params \\ %{"view" => "values"}),
    do: ContractFixtures.settings_query_request(params, request_id: "local-q")

  defp command(params),
    do: ContractFixtures.settings_command_request(params, request_id: "local-c")

  defp provider_record(api_key) do
    %{
      "kind" => "provider",
      "id" => @provider,
      "fields" => %{"name" => "DeepSeek", "api_key" => api_key, "base_url" => "https://x.test/v1"}
    }
  end

  defp record_snapshot(record),
    do: ContractFixtures.settings_snapshot_value("record", record, request_id: @wire)

  defp value(key, value, extra \\ %{}) do
    Map.merge(
      %{
        "key" => key,
        "value" => value,
        "layers" => [
          %{
            "layer" => "global",
            "value" => value,
            "set" => true,
            "ignored" => false,
            "raw" => nil,
            "source" => nil,
            "note" => nil
          }
        ],
        "winner" => "global",
        "writable" => ["global"],
        "base" => value,
        "choices" => nil,
        "state" => "ok",
        "note" => nil
      },
      extra
    )
  end

  defp values_snapshot(values),
    do:
      ContractFixtures.settings_snapshot_value(
        "values",
        %{"values" => values, "project_id" => nil, "conversation_id" => nil},
        request_id: @wire
      )

  describe "requests" do
    test "constructors fill the exact wire parameter sets and validate with WireBounds" do
      request = query(%{view: "overview"})
      assert {:settings_query, params} = request.kind

      assert Enum.sort(Map.keys(params)) ==
               Enum.sort(ContractFixtures.settings_param_keys(:query))

      assert request.scope == @global and request.expected_response == :settings_snapshot

      cmd = command(%{"action" => "values.reset", "attributes" => %{"scope" => "all"}})
      assert {:settings_command, cparams} = cmd.kind
      assert cparams["secrets"] == [] and cparams["dry_run"] == false
      assert cmd.expected_response == :settings_result
      assert {:ok, _} = Effect.validate({:command, cmd})
      assert {:ok, _} = Effect.validate({:query, request})
    end

    test "an oversize edit is refused locally with the parameter it breaks" do
      long = String.duplicate("x", 262_145)

      assert {:error, {:too_long, "attributes"}} =
               Request.settings_command(
                 %{"action" => "file.save", "attributes" => %{"content" => long}},
                 {:settings, 1, :save},
                 5_000,
                 request_id: "r",
                 generation: 3
               )

      assert Request.too_long_words("attributes") ==
               "That is too long to save here (attributes)"

      assert {:error, {:too_long, "view"}} =
               Request.settings_query(%{"view" => "nope"}, {:settings, 1, :x}, 5_000,
                 request_id: "r",
                 generation: 3
               )

      # A settings request never leaves the global scope.
      shell = Request.settings_query(%{"view" => "values"}, {:settings, 1, :open}, 5_000)

      conversation = %{
        shell
        | request_id: "r",
          generation: 3,
          scope: %Scope{
            kind: :conversation,
            id: "4f2a0000-0000-4000-8000-000000000001",
            generation: 3
          }
      }

      assert {:error, :invalid_request} = Request.validate(conversation)

      assert {:error, :invalid_request} =
               Request.validate(%{conversation | scope: @global, origin: {:settings, 0, :x}})
    end

    test "the codec sends the exact op body and the service decodes it" do
      for {op, request} <- RequestConformance.settings_rows() do
        assert {:ok, message} = Codec.request(request, @wire, @nonce, 1_788_438_390_000)
        assert message.body["op"] == op
        assert message.body["timeout_ms"] == 10_000
        assert message.scope == @global
        assert {:ok, decoded} = ServiceRequest.decode(message.body, message.scope)
        assert Atom.to_string(decoded.operation) == String.replace(op, ".", "_")
      end
    end

    test "inspect never shows a pasted secret" do
      cmd =
        command(%{
          "action" => "provider.set_key",
          "target" => %{"id" => @provider},
          "attributes" => %{"test_first" => false},
          "secrets" => [%{"slot" => "key", "value" => @canary}]
        })

      refute inspect(cmd) =~ @canary
      assert inspect(cmd) =~ "1 redacted"
      assert {:ok, message} = Codec.request(cmd, @wire, @nonce, 1_788_438_390_000)
      assert message.body["secrets"] == [%{"slot" => "key", "value" => @canary}]
    end
  end

  describe "responses" do
    test "a values snapshot decodes; an unknown key is dropped; an invalid scalar only marks itself" do
      value =
        values_snapshot([
          value("limits.max_concurrent_agents", 6),
          value("limits.max_agent_turns", "sixty"),
          value("from.a.newer.daemon", 1)
        ])

      log =
        capture_log([level: :info], fn ->
          assert {:ok, %Delivery{body: %DTO.SettingsSnapshot{} = snapshot}} =
                   Codec.response(
                     result_message("settings_snapshot", value),
                     query(),
                     @wire,
                     @nonce
                   )

          send(self(), {:snapshot, snapshot})
        end)

      assert_received {:snapshot, snapshot}
      assert snapshot.request_id == "local-q" and snapshot.view == :values
      assert [ok, bad] = snapshot.body.values
      assert ok.key == "limits.max_concurrent_agents" and ok.value == 6 and ok.state == :ok
      assert ok.winner == :global and ok.writable == [:global]
      assert bad.key == "limits.max_agent_turns" and bad.state == :invalid and bad.value == nil
      assert log =~ "unknown key from.a.newer.daemon"
    end

    test "a whole-number float reads as an integer (50.0 is 50)" do
      value = values_snapshot([value("budget.monthly_usd", 50.0)])

      assert {:ok, %Delivery{body: %DTO.SettingsSnapshot{body: body}}} =
               Codec.response(result_message("settings_snapshot", value), query(), @wire, @nonce)

      assert [%{value: 50, state: :ok}] = body.values
    end

    test "a secret field as a string, a 5-character hint or an extra key refuses the whole answer" do
      for bad <- [
            "sk-test-deepseek-00000000a1b2",
            %{"set" => true, "hint" => "a1b2c"},
            %{"set" => true, "hint" => "a1b2", "value" => "x"},
            %{"set" => "yes", "hint" => nil}
          ] do
        log =
          capture_log(fn ->
            assert {:ok, %Delivery{body: body}} =
                     Codec.response(
                       result_message("settings_snapshot", record_snapshot(provider_record(bad))),
                       query(%{"view" => "record", "kind" => "provider", "id" => @provider}),
                       @wire,
                       @nonce
                     )

            send(self(), {:body, body})
          end)

        assert_received {:body,
                         {:settings_failed, "local-q", "Couldn't read settings right now."}}

        assert log =~ "settings response rejected: secret field shape (provider.api_key)"
        refute log =~ "a1b2"
      end

      assert {:ok, %Delivery{body: %DTO.SettingsSnapshot{body: record}}} =
               Codec.response(
                 result_message(
                   "settings_snapshot",
                   record_snapshot(provider_record(%{"set" => true, "hint" => "a1b2"}))
                 ),
                 query(%{"view" => "record", "kind" => "provider", "id" => @provider}),
                 @wire,
                 @nonce
               )

      assert record.fields["api_key"] == %{set: true, hint: "a1b2"}
    end

    test "a settings_result record keeps the same secret rule" do
      value =
        ContractFixtures.settings_result_value("accepted",
          request_id: @wire,
          record: provider_record(%{"set" => true, "hint" => "toolong"})
        )

      capture_log(fn ->
        assert {:ok, %Delivery{body: {:settings_failed, "local-c", _}}} =
                 Codec.response(
                   result_message("settings_result", value),
                   command(%{"action" => "provider.update", "target" => %{"id" => @provider}}),
                   @wire,
                   @nonce
                 )
      end)
    end

    test "an MCP entry is refused when a secret carries a value or a shown value looks secret" do
      server = fn env ->
        %{
          "kind" => "mcp_server",
          "id" => "3c9a0000-0000-4000-8000-000000000001",
          "fields" => %{"env" => env}
        }
      end

      shown = %{"name" => "GITHUB_TOOLSETS", "secret" => false, "value" => "repos", "hint" => nil}

      masked = %{
        "name" => "GITHUB_PERSONAL_ACCESS_TOKEN",
        "secret" => true,
        "value" => nil,
        "hint" => "i9j0"
      }

      request = query(%{"view" => "record", "kind" => "mcp_server", "id" => "x"})

      assert {:ok, %Delivery{body: %DTO.SettingsSnapshot{body: record}}} =
               Codec.response(
                 result_message("settings_snapshot", record_snapshot(server.([shown, masked]))),
                 request,
                 @wire,
                 @nonce
               )

      assert [%{value: "repos"}, %{secret: true, value: nil, hint: "i9j0"}] = record.fields["env"]

      for bad <- [
            %{masked | "value" => "ghp_test_0000000000000000i9j0"},
            %{
              "name" => "OTHER",
              "secret" => false,
              "value" => "ghp_test_0000000000000000i9j0",
              "hint" => nil
            }
          ] do
        capture_log(fn ->
          assert {:ok, %Delivery{body: {:settings_failed, "local-q", _}}} =
                   Codec.response(
                     result_message("settings_snapshot", record_snapshot(server.([bad]))),
                     request,
                     @wire,
                     @nonce
                   )
        end)
      end
    end

    test "an outcome reply to a settings command is a SettingsResult whose outcome is unknown" do
      outcome = %{
        "request_id" => @wire,
        "status" => "deadline_exceeded",
        "error" => nil,
        "corrective_action" => "refresh",
        "feedback" => nil
      }

      cmd = command(%{"action" => "values.patch", "attributes" => %{"changes" => []}})

      assert {:ok, %Delivery{body: %DTO.SettingsResult{} = result}} =
               Codec.response(result_message("outcome", outcome), cmd, @wire, @nonce)

      assert result.status == :unavailable and result.corrective_action == :refresh
      assert result.message == "Couldn't tell whether that was saved; reloading."
      assert result.request_id == "local-c"

      assert {:ok, %Delivery{body: %DTO.SettingsResult{status: :rejected}}} =
               Codec.response(
                 result_message("outcome", %{outcome | "status" => "rejected"}),
                 cmd,
                 @wire,
                 @nonce
               )

      # An outcome to a query, or any other kind, is a daemon bug: the one close path.
      assert {:error, %AdmissionError{code: :invalid_request}} =
               Codec.response(result_message("outcome", outcome), query(), @wire, @nonce)

      assert {:error, %AdmissionError{code: :invalid_request}} =
               Codec.response(result_message("shell_snapshot", %{}), query(), @wire, @nonce)
    end

    test "a settings_result decodes rows, task, field errors and revision" do
      value =
        ContractFixtures.settings_result_value("conflict",
          request_id: @wire,
          results: [
            %{
              "target" => "limits.max_concurrent_agents",
              "status" => "conflict",
              "value" => nil,
              "current" => 8,
              "message" => nil
            },
            %{
              "target" => "limits.max_agent_turns",
              "status" => "skipped",
              "value" => nil,
              "current" => nil,
              "message" => nil
            }
          ],
          field_errors: [%{"target" => "name", "message" => "can't be blank"}],
          task: %{"task_id" => "t-1", "action" => "provider.test"},
          revision: 44
        )

      assert {:ok, %Delivery{body: %DTO.SettingsResult{} = result}} =
               Codec.response(
                 result_message("settings_result", value),
                 command(%{"action" => "values.patch"}),
                 @wire,
                 @nonce
               )

      assert result.status == :conflict and result.revision == 44
      assert [%{status: :conflict, current: 8}, %{status: :skipped}] = result.results
      assert result.task == %{task_id: "t-1", action: "provider.test"}
      assert result.field_errors == [%{target: "name", message: "can't be blank"}]
    end

    test "a data-source failure of a settings request is typed, never an outcome" do
      {_source, client} = fake(settings: [integrations: false])
      Fake.close(client)

      context = %{
        data_source: client,
        owner: self(),
        source_epoch: "epoch",
        local: fn _ -> flunk("unexpected local effect") end
      }

      request = fake_query(%{"view" => "values"}, "r-closed")
      assert :ok = EffectRunner.run({:query, request}, context)
      assert_receive {:swarm_code_ui_data, "epoch", %Delivery{body: body} = delivery}
      assert {:ok, _} = Delivery.validate(delivery)
      assert {:settings_failed, "r-closed", "data source is closed"} = body
    end
  end

  describe "deltas" do
    defp event(sequence, delta),
      do: %Message{
        version: 1,
        type: :event,
        request_id: nil,
        nonce: @nonce,
        scope: %Scope{
          kind: :conversation,
          id: "4f2a0000-0000-4000-8000-000000000001",
          generation: 3
        },
        sequence: sequence,
        occurred_at: "2026-09-25T00:00:00Z",
        body: %{"op" => "delta", "watch_ref" => @watch_ref, "value" => delta}
      }

    defp shell_watch,
      do: %Watch{
        watch_ref: @watch_ref,
        slot: :shell,
        scope: %Scope{
          kind: :conversation,
          id: "4f2a0000-0000-4000-8000-000000000001",
          generation: 3
        },
        generation: 3,
        page_size: 20,
        byte_limit: 262_144
      }

    defp delta(kind, entity, body, sequence),
      do: %{
        "kind" => kind,
        "entity_id" => entity,
        "run_id" => nil,
        "conversation_id" => nil,
        "channel" => nil,
        "attempt_id" => nil,
        "text" => nil,
        "body" => body,
        "sequence" => sequence,
        "revision" => 9
      }

    test "settings_update and settings_task cross any scope as global facts" do
      update = %{
        "revision" => 43,
        "sections" => ["agents_limits", "from_the_future"],
        "origin" => "elsewhere"
      }

      assert {:ok, %Delivery{kind: :delta, body: %Delta{kind: :settings_update, body: body}}} =
               Codec.event(
                 event(4, delta("settings_update", nil, update, 4)),
                 shell_watch(),
                 @nonce
               )

      assert body == %DTO.SettingsUpdate{
               revision: 43,
               sections: [:agents_limits],
               origin: :elsewhere
             }

      task = %{
        "task_id" => "7a5c0000-0000-4000-8000-000000000001",
        "action" => "provider.test",
        "target" => %{"id" => @provider},
        "state" => "running",
        "elapsed_ms" => 250,
        "progress" => %{"done" => 1, "total" => 2, "bytes" => nil, "step" => "listing models"},
        "summary" => nil,
        "message" => nil
      }

      assert {:ok, %Delivery{body: %Delta{kind: :settings_task, body: %DTO.SettingsTask{} = t}}} =
               Codec.event(
                 event(5, delta("settings_task", task["task_id"], task, 5)),
                 shell_watch(),
                 @nonce
               )

      assert t.state == :running and t.progress.step == "listing models"

      # A task delta must name its task.
      assert {:error, _} =
               Codec.event(event(6, delta("settings_task", nil, task, 6)), shell_watch(), @nonce)
    end
  end

  describe "Fake.Settings" do
    defp fake(opts) do
      {:ok, script} =
        Script.decode(
          File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
        )

      source =
        start_supervised!(
          {Source, [script: script, source_epoch: "epoch"] ++ opts},
          id: make_ref()
        )

      client =
        start_supervised!(
          {Fake, source: source, source_epoch: "epoch", client_id: "client"},
          id: make_ref()
        )

      {source, client}
    end

    defp bound(opts) do
      {source, client} = fake(opts)
      {:ok, _} = Fake.bind_owner(client, self(), "binding")

      watch = %Watch{
        watch_ref: "shell",
        slot: :shell,
        scope: %Scope{kind: :global, id: nil, generation: 0},
        generation: 0,
        page_size: 50,
        byte_limit: 1_048_576
      }

      :ok = Fake.watch(client, watch)
      assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :watch_ready}}, 2_000
      {source, client}
    end

    defp fake_query(params, id) do
      {:ok, request} =
        Request.settings_query(params, {:settings, 1, :test}, Script.clock_ms() + 10_000,
          request_id: id,
          generation: 0
        )

      request
    end

    defp fake_command(params, id) do
      {:ok, request} =
        Request.settings_command(params, {:settings, 1, :test}, Script.clock_ms() + 10_000,
          request_id: id,
          generation: 0
        )

      request
    end

    defp ask(client, %Request{expected_response: :settings_snapshot} = request) do
      :ok = Fake.query(client, request)
      id = request.request_id

      assert_receive {:swarm_code_ui_data, "epoch",
                      %Delivery{kind: :response, request_id: ^id, body: body}},
                     2_000

      body
    end

    defp ask(client, request) do
      :ok = Fake.command(client, request)
      id = request.request_id

      assert_receive {:swarm_code_ui_data, "epoch",
                      %Delivery{kind: :response, request_id: ^id, body: body}},
                     2_000

      body
    end

    defp next_delta(kind) do
      assert_receive {:swarm_code_ui_data, "epoch",
                      %Delivery{kind: :delta, body: %Delta{kind: ^kind, body: body}}},
                     2_000

      body
    end

    test "answers every generic view from the Appendix A seed" do
      {_source, client} = bound(settings: [integrations: false])

      values = ask(client, fake_query(%{"view" => "values"}, "q-values"))
      assert %DTO.SettingsSnapshot{view: :values, available: true} = values
      by_key = Map.new(values.body.values, &{&1.key, &1})
      assert by_key["limits.max_concurrent_agents"].value == 6
      assert by_key["session.model"].winner == :flag
      assert Enum.all?(by_key, fn {_, v} -> v.state == :ok end)
      effort = by_key["efforts.default"]
      assert Enum.any?(effort.layers, &(&1.layer == :project_file and &1.ignored))
      assert effort.winner == :default

      for view <- ~w(overview facts usage open) do
        assert %DTO.SettingsSnapshot{available: true, body: body} =
                 ask(client, fake_query(%{"view" => view}, "q-" <> view))

        assert body != nil
      end

      open = ask(client, fake_query(%{"view" => "open"}, "q-open-2"))
      assert [first, _] = open.body.projects.items
      assert first.fields["name"] == "ailogic"
      assert [%{severity: :error} | _] = open.body.overview.attention

      page = ask(client, fake_query(%{"view" => "records", "kind" => "projects"}, "q-projects"))
      assert %DTO.SettingsRecordPage{kind: "projects", total: 2} = page.body

      gone = ask(client, fake_query(%{"view" => "task", "id" => "nope"}, "q-task"))

      assert %DTO.SettingsSnapshot{available: false, message: "that result is gone; run it again"} =
               gone
    end

    test "values.patch writes with compare-and-set; a second writer conflicts" do
      {source, client} = bound(settings: [integrations: false])
      key = "limits.max_concurrent_agents"

      patch = fn id, value, expected ->
        fake_command(
          %{
            "action" => "values.patch",
            "attributes" => %{"changes" => [%{"key" => key, "value" => value, "target" => nil}]},
            "expected" => %{key => expected}
          },
          id
        )
      end

      assert %DTO.SettingsResult{status: :accepted, results: [%{status: :accepted}]} =
               ask(client, patch.("c1", 8, 6))

      assert %DTO.SettingsUpdate{origin: :settings, sections: [:agents_limits]} =
               next_delta(:settings_update)

      assert %DTO.SettingsResult{status: :conflict, results: [%{current: 8}]} =
               ask(client, patch.("c2", 9, 6))

      assert %DTO.SettingsResult{status: :unchanged} = ask(client, patch.("c3", 8, 8))

      assert %DTO.SettingsResult{status: :rejected, results: [%{message: message}]} =
               ask(client, patch.("c4", 0, 8))

      assert message =~ "must be"

      :ok = Fake.Settings.put(source, key, 3)
      assert %DTO.SettingsUpdate{origin: :elsewhere} = next_delta(:settings_update)
      assert Fake.Settings.state(source).global[key] == 3
    end

    test "provider and effort service checks, reset, profile and a session write clearing --model" do
      {source, client} = bound(settings: [integrations: false])

      change = fn id, key, value ->
        fake_command(
          %{
            "action" => "values.patch",
            "attributes" => %{"changes" => [%{"key" => key, "value" => value, "target" => nil}]},
            "expected" => %{key => %{"$any" => true}}
          },
          id
        )
      end

      missing = %{"provider_id" => "99999999-9999-4999-8999-999999999999", "model" => "x"}

      assert %DTO.SettingsResult{
               status: :rejected,
               results: [%{message: "that provider no longer exists"}]
             } =
               ask(client, change.("p1", "models.chat", missing))

      assert %DTO.SettingsResult{status: :rejected, results: [%{message: effort_words}]} =
               ask(client, change.("p2", "session.effort", "max"))

      assert effort_words =~ "is not a level of deepseek-v4-pro"

      assert %DTO.SettingsResult{status: :accepted} =
               ask(
                 client,
                 change.("p3", "session.model", %{
                   "provider_id" => @provider,
                   "model" => "deepseek-v4-flash"
                 })
               )

      assert Fake.Settings.state(source).flag_model == nil

      reset =
        fake_command(
          %{
            "action" => "values.reset",
            "attributes" => %{"keys" => ["limits.max_concurrent_agents"]},
            "expected" => %{"limits.max_concurrent_agents" => 6}
          },
          "r1"
        )

      assert %DTO.SettingsResult{status: :accepted} = ask(client, reset)
      assert Fake.Settings.state(source).global["limits.max_concurrent_agents"] == 4

      apply = fn id, name ->
        fake_command(%{"action" => "profile.apply", "attributes" => %{"name" => name}}, id)
      end

      assert %DTO.SettingsResult{status: :accepted} = ask(client, apply.("f1", "fast"))
      assert Fake.Settings.state(source).session["session.effort"] == "low"

      assert %DTO.SettingsResult{
               status: :rejected,
               message: "Unknown profile \"slow\" — available: fast"
             } =
               ask(client, apply.("f2", "slow"))
    end

    test "S2 actions are unsupported without the integrations; stubs, failures and outcome replies" do
      {source, client} = bound(settings: [integrations: false])

      set_key =
        fake_command(
          %{
            "action" => "provider.set_key",
            "target" => %{"id" => @provider},
            "attributes" => %{"test_first" => false},
            "secrets" => [%{"slot" => "key", "value" => @canary}]
          },
          "k1"
        )

      assert %DTO.SettingsResult{status: :unsupported} = ask(client, set_key)

      [logged] = Fake.Settings.requests(source) |> Enum.filter(&(&1["op"] == "settings.command"))
      assert logged["secrets"] == [%{"slot" => "key", "value" => "[REDACTED]"}]
      refute inspect(Fake.Settings.requests(source)) =~ @canary

      sha = :sha256 |> :crypto.hash(@canary) |> Base.encode16(case: :lower)
      assert Fake.Settings.secret_writes(source) == [{"provider.set_key", "key", sha}]

      :ok =
        Fake.Settings.stub_reply(source, "project_config.put_hook", %{
          status: :needs_confirmation,
          confirm: %{"kind" => "hooks", "items" => ["mix format"]}
        })

      assert %DTO.SettingsResult{status: :needs_confirmation, confirm: %{kind: "hooks"}} =
               ask(client, fake_command(%{"action" => "project_config.put_hook"}, "s1"))

      :ok =
        Fake.Settings.fail_next(source, "values.patch", %{
          status: "rejected",
          message: "no",
          field_errors: [%{target: "limits.max_agent_turns", message: "must be at least 1"}]
        })

      assert %DTO.SettingsResult{
               status: :rejected,
               field_errors: [%{message: "must be at least 1"}]
             } =
               ask(client, fake_command(%{"action" => "values.patch"}, "s2"))

      :ok = Fake.Settings.reply_outcome_next(source, :deadline_exceeded)

      assert %DTO.SettingsResult{status: :unavailable, corrective_action: :refresh} =
               ask(client, fake_command(%{"action" => "values.patch"}, "s3"))
    end

    test "the generic task lifecycle: running, step, hold/release, cancel, task view" do
      {source, client} = bound(settings: [integrations: false])

      :ok =
        Fake.Settings.stub_reply(
          source,
          "doctor",
          {:task, %{"ok" => 3}, [%{"id" => "db", "ok" => true, "message" => "readable"}]}
        )

      assert %DTO.SettingsResult{status: :accepted, task: %{task_id: id}} =
               ask(client, fake_command(%{"action" => "doctor"}, "t1"))

      assert %DTO.SettingsTask{state: :running, task_id: ^id} = next_delta(:settings_task)

      running = ask(client, fake_query(%{"view" => "task", "id" => id}, "t1q"))
      assert %DTO.SettingsTaskView{state: :running, rows: []} = running.body

      :ok = Fake.step(client)
      assert %DTO.SettingsTask{state: :done, summary: %{"ok" => 3}} = next_delta(:settings_task)

      done = ask(client, fake_query(%{"view" => "task", "id" => id}, "t1d"))
      assert %DTO.SettingsTaskView{state: :done, total: 1, rows: [%{"id" => "db"}]} = done.body

      :ok = Fake.Settings.hold_task(source, "doctor")

      assert %DTO.SettingsResult{task: %{task_id: held}} =
               ask(client, fake_command(%{"action" => "doctor"}, "t2"))

      assert %DTO.SettingsTask{state: :running} = next_delta(:settings_task)
      :ok = Fake.step(source)
      refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :delta}}, 50
      :ok = Fake.Settings.release_task(source, "doctor", {:error, "no answer in 5 s"})

      assert %DTO.SettingsTask{state: :failed, message: "no answer in 5 s", task_id: ^held} =
               next_delta(:settings_task)

      assert %DTO.SettingsResult{task: %{task_id: third}} =
               ask(client, fake_command(%{"action" => "doctor"}, "t3"))

      assert %DTO.SettingsTask{state: :running} = next_delta(:settings_task)

      cancel =
        fake_command(%{"action" => "task.cancel", "target" => %{"task_id" => third}}, "t3c")

      assert %DTO.SettingsResult{status: :accepted} = ask(client, cancel)
      assert %DTO.SettingsTask{state: :cancelled} = next_delta(:settings_task)
    end

    test "auto_tasks finishes a task at once" do
      {source, client} = bound(settings: [integrations: false, auto_tasks: true])
      :ok = Fake.Settings.stub_reply(source, "doctor", {:task, %{"ok" => 1}})

      assert %DTO.SettingsResult{task: %{}} =
               ask(client, fake_command(%{"action" => "doctor"}, "a1"))

      assert %DTO.SettingsTask{state: :running} = next_delta(:settings_task)
      assert %DTO.SettingsTask{state: :done} = next_delta(:settings_task)
    end
  end
end
