defmodule SwarmCode.Daemon.Service.Settings.C020ValuesTest do
  @moduledoc """
  cli020 C13 (ux-live-11, onboarding-19): the settings say where a model
  override came from, and "modified" means "differs from what it would be".
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.Settings
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Settings.Setting
  alias SwarmCode.Test.C74S1

  setup do
    %{dir: dir} = C74S1.repo!("c020-values")
    Repo.delete_all(Setting)

    provider =
      C74S1.provider!(%{
        name: "Fixture",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:9/v1",
        api_key: "",
        models: ["fixture-model"],
        default_model: "fixture-model"
      })

    project = C74S1.project!(dir, "fresh")
    conversation = C74S1.conversation!(project)

    on_exit(fn -> Application.delete_env(:swarm_code_daemon, :session_model_override) end)
    %{project: project, conversation: conversation, provider: provider}
  end

  defp values(fixture, fields \\ []) do
    ctx =
      Settings.Context.new(
        Keyword.merge(
          [
            project: fixture.project,
            conversation: fixture.conversation,
            env: %{},
            request_id: "11111111-1111-4111-8111-111111111111"
          ],
          fields
        )
      )

    {:ok, %{"values" => values}} = Settings.query("values", %{}, ctx)
    Map.new(values, &{&1["key"], &1})
  end

  test "a fresh database reports nothing modified", fixture do
    modified = for {key, %{"modified" => true}} <- values(fixture), do: key
    assert modified == []
  end

  test "a conversation-scoped value is never in the global modified count", fixture do
    {:ok, _} =
      SwarmCode.Domain.Conversations.update(fixture.conversation, %{effort: "high", mode: "plan"})

    by_key = values(fixture)
    assert by_key["session.effort"]["winner"] == "session"
    assert by_key["session.effort"]["modified"] == false
    assert by_key["session.mode"]["modified"] == false
  end

  test "a changed global value is modified", fixture do
    {:ok, _} = Repo.insert(%Setting{max_concurrent_agents: 9})
    assert values(fixture)["limits.max_concurrent_agents"]["modified"] == true
  end

  test "the --model flag and a first-run env override say which they are", fixture do
    override = %{provider_id: fixture.provider.id, model: "fixture-model"}
    Application.put_env(:swarm_code_daemon, :session_model_override, override)

    flag = Enum.find(values(fixture, override: override)["session.model"]["layers"], & &1["set"])

    assert {flag["layer"], flag["source"], flag["note"]} ==
             {"flag", "--model", "this launch only"}

    first_run = Map.put(override, :source, :first_run_env)
    Application.put_env(:swarm_code_daemon, :session_model_override, first_run)
    layers = values(fixture, override: first_run)["session.model"]["layers"]
    env = Enum.find(layers, & &1["set"])
    assert {env["layer"], env["source"], env["note"]} == {"env", "NCODE_MODEL", "first run"}
    refute Enum.any?(layers, &(&1["source"] == "--model"))
  end

  # cli020 C17 + E1: the registry's Validator entries read the columns.
  describe "C17 validator storage" do
    alias SwarmCode.Daemon.Service.Settings.{Context, Values}
    alias SwarmCode.Settings.Registry

    defp entry(key), do: Registry.fetch!(key)

    test "the global and conversation validator columns read back", fixture do
      {:ok, _} =
        Repo.insert(%Setting{
          default_validator_provider_id: fixture.provider.id,
          default_validator_model: "fixture-model",
          default_validator_effort: "high"
        })

      {:ok, conv} =
        SwarmCode.Domain.Conversations.update(fixture.conversation, %{
          validator_provider_id: fixture.provider.id,
          validator_model: "fixture-model",
          validator_effort: "low"
        })

      ctx =
        Context.new(
          project: fixture.project,
          conversation: conv,
          env: %{},
          request_id: "11111111-1111-4111-8111-111111111111"
        )

      reads = Values.read(ctx, fixture.project.id)

      global =
        Values.setting_value(
          entry("models.validator"),
          reads
        )

      assert global["value"] == %{
               "provider_id" => fixture.provider.id,
               "model" => "fixture-model"
             }

      effort =
        Values.setting_value(
          entry("efforts.validator"),
          reads
        )

      assert effort["value"] == "high"
      assert is_list(effort["choices"]) and effort["choices"] != []

      session =
        Values.setting_value(
          entry("session.validator_model"),
          reads
        )

      assert {session["winner"], session["value"]["model"]} == {"session", "fixture-model"}
    end
  end
end
