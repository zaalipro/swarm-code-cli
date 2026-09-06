defmodule SwarmCodeCLI.UI.PipelineContractsTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.TestSupport.ContractFixtures
  alias SwarmCodeCLI.UI.{Effect, SafeText, Scene, Theme}
  alias SwarmCodeCLI.UI.RequestResolver
  alias SwarmCodeCLI.UI.Scene.Block.RunCard
  alias SwarmCodeCLI.UI.DataSource.DTO.RunSummary

  test "every domain run state retains its exact word through the Scene boundary" do
    for state <- [
          :queued,
          :running,
          :streaming,
          :waiting_question,
          :waiting_approval,
          :paused,
          :retrying,
          :done,
          :failed,
          :stopped,
          :interrupted,
          :superseded
        ] do
      run = %RunSummary{id: "run", conversation_id: "conversation", state: state}
      assert {:ok, _} = RunSummary.validate(run)
      {label, _tone} = Theme.status(state)
      scene = ContractFixtures.minimal_scene(SafeText.chrome(:main))
      region = hd(scene.regions)
      card = %RunCard{id: run.id, title: label, status: run.state}
      assert :ok = Scene.validate(%{scene | regions: [%{region | blocks: [card]}]})
    end
  end

  test "unsafe external announcements return static validation errors without raising" do
    forged = %SafeText{token: {:external, "\e]52;c;owned\a"}}
    assert {:error, :invalid_effect} = Effect.validate({:announce, forged})
    assert_raise ArgumentError, "invalid effect", fn -> Effect.validate!({:announce, forged}) end
  end

  test "authorization is shared without fabricating a request identity" do
    context = ContractFixtures.failed_run_context("failed", 12, allowed_actions: [:retry])
    intent = {:retry_run, "failed", 12}
    assert :ok = RequestResolver.authorize(intent, context)
    assert {:ok, _} = RequestResolver.resolve(intent, context, "real-request", 1000)

    for {bad_intent, bad_context, reason} <- [
          {intent, %{context | allowed_actions: []}, :not_allowed},
          {{:retry_run, "failed", 11}, context, :stale_revision},
          {{:retry_run, "another", 12}, context, :invalid_origin},
          {intent, %{context | scope_generation: 99}, :invalid_origin},
          {:unknown, context, :invalid_intent}
        ] do
      assert {:error, ^reason} = RequestResolver.authorize(bad_intent, bad_context)

      assert {:error, ^reason} =
               RequestResolver.resolve(bad_intent, bad_context, "real-request", 1000)
    end
  end
end
