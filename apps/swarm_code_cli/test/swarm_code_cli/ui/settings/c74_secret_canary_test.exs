defmodule SwarmCodeCLI.UI.Settings.C74SecretCanaryTest do
  @moduledoc """
  cli74 U1-10: a pasted secret (the canary) travels once, inside the
  command's `secrets`, and nowhere else: not in the scene, the state (as a
  term, not only its inspect output), undo, the changelog, toasts, the
  kept request copy or the log. Typing is ignored unless Ctrl-T; a
  replaced key is checked first and a refusal sends nothing more unless
  `s`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCodeCLI.UI.{Projector, Reducer, SafeText}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Reducer.Settings.{Ops, Responses}

  @canary "sk-canary-7Q2X-DO-NOT-SHOW"

  defp act(state, action), do: Reducer.update(state, action)
  defp act!(state, action), do: elem(act(state, action), 0)

  defp sent(effects),
    do: for({kind, %Request{} = r} <- effects, kind in [:query, :command], do: r)

  defp deliver(state, request, body) do
    act(
      state,
      {:data,
       %Delivery{
         kind: :response,
         watch_ref: nil,
         request_id: request.request_id,
         scope: request.scope,
         generation: request.generation,
         revision: nil,
         sequence: nil,
         body: body
       }}
    )
  end

  defp serve({state, effects}, fake) do
    Enum.reduce(sent(effects), {state, fake}, fn request, {acc, fake} ->
      {fake, body, _} =
        case request.kind do
          {:settings_query, _} -> FakeSettings.query(fake, request)
          {:settings_command, _} -> FakeSettings.command(fake, request)
        end

      {acc, _} = deliver(acc, request, body)
      {acc, fake}
    end)
  end

  defp screen(state) do
    {scene, _} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map_join("\n", fn block ->
      Enum.map_join(block.spans, "", &SafeText.value(&1.text))
    end)
  end

  defp target(extra \\ %{}) do
    Map.merge(
      %{
        row_id: "key:terminal.panel",
        action: "search.set_key",
        target: %{"id" => "tavily"},
        attributes: %{},
        slot: "api_key",
        label: "Tavily API key",
        set?: false
      },
      extra
    )
  end

  defp clean?(term), do: not String.contains?(:erlang.term_to_binary(term), @canary)

  # A terminal that marks pastes (typing is then ignored until Ctrl-T).
  defp opened do
    fake = FakeSettings.seed()
    state = ready()
    state = %{state | capabilities: %{state.capabilities | paste: :supported}}
    {state, fake} = state |> act({:settings_open, {:key, "terminal.panel"}}) |> serve(fake)
    {state, fake}
  end

  test "the canary travels once in the command's secrets and nowhere else" do
    log =
      capture_log(fn ->
        {state, fake} = opened()

        {:ok, fake, []} =
          FakeSettings.control(fake, :stub_reply, ["search.set_key", %{status: :accepted}])

        {state, _} = Ops.run(state, [{:paste, target()}])
        assert state.settings.mode == :paste

        state = act!(state, {:settings, {:paste, @canary}})
        text = screen(state)
        refute text =~ @canary
        assert text =~ "●●●●●●●● pasted · not shown"
        refute inspect(state) =~ @canary
        refute inspect(state.settings) =~ @canary

        {state, effects} = act(state, {:settings, {:verb, :paste_commit}})
        [request] = sent(effects)
        {:settings_command, params} = request.kind
        assert [%{"slot" => "api_key", "value" => @canary}] = params["secrets"]
        refute Map.values(params["attributes"]) |> inspect() =~ @canary
        refute inspect(request) =~ @canary

        # The paste is gone once the command leaves; the kept copy has no secrets.
        assert state.settings.paste == nil
        assert clean?(state)

        {fake, body, _} = FakeSettings.command(fake, request)
        {requests, _, _} = FakeSettings.control(fake, :requests, [])
        assert Enum.any?(requests, &match?(%{"secrets" => [%{"value" => "[REDACTED]"}]}, &1))
        {writes, _, _} = FakeSettings.control(fake, :secret_writes, [])
        digest = :sha256 |> :crypto.hash(@canary) |> Base.encode16(case: :lower)
        assert [{"search.set_key", "api_key", ^digest}] = writes

        {state, _} = deliver(state, request, body)
        assert state.settings.status.text == "Tavily API key saved"
        assert clean?(state)
        assert clean?(state.settings_history)
        refute screen(state) =~ @canary
      end)

    refute log =~ @canary
  end

  test "typing is ignored unless Ctrl-T (typed characters are never echoed)" do
    {state, _fake} = opened()
    {state, _} = Ops.run(state, [{:paste, target()}])

    state = act!(state, {:settings, {:text, "x"}})
    assert state.settings.paste.bytes == ""

    assert state.settings.status.text ==
             "typing is ignored here · paste with Cmd-V · Ctrl-T types instead"

    state = act!(state, {:settings, {:verb, :paste_type}})

    state =
      Enum.reduce(String.graphemes("abcdefgh12"), state, &act!(&2, {:settings, {:text, &1}}))

    assert state.settings.paste.bytes == "abcdefgh12"
    assert screen(state) =~ "typing · not shown"
    refute screen(state) =~ "abcdefgh12"
  end

  test "the checks: one line, no inner space, the 8-byte floor" do
    {state, _fake} = opened()
    {state, _} = Ops.run(state, [{:paste, target()}])

    for {bytes, words} <- [
          {"short", "that is too short to be a key"},
          {"two\nlines-of-key", "the paste had 2 lines; paste only the key"},
          {"has inner space", "a key has no spaces inside"}
        ] do
      pasted = act!(state, {:settings, {:paste, bytes}})
      {checked, effects} = act(pasted, {:settings, {:verb, :paste_commit}})
      assert sent(effects) == []
      assert checked.settings.paste.refused == words
    end
  end

  test "Esc drops the paste and sends nothing" do
    {state, _fake} = opened()
    {state, _} = Ops.run(state, [{:paste, target()}])
    state = act!(state, {:settings, {:paste, @canary}})
    {state, effects} = act(state, {:settings, {:verb, :escape}})
    assert sent(effects) == []
    assert state.settings.paste == nil
    assert clean?(state)
  end

  test "a replaced key is checked first; a refusal sends nothing more unless s" do
    {state, fake} = opened()
    {:ok, fake, []} = FakeSettings.control(fake, :stub_reply, ["search.set_key", {:task, %{}}])
    {state, _} = Ops.run(state, [{:paste, target(%{set?: true})}])
    state = act!(state, {:settings, {:paste, @canary}})

    {state, effects} = act(state, {:settings, {:verb, :paste_commit}})
    [request] = sent(effects)
    {:settings_command, params} = request.kind
    assert params["attributes"]["test_first"] == true
    assert state.settings.paste.pending_task == :sent

    {_fake, body, _} = FakeSettings.command(fake, request)
    {state, _} = deliver(state, request, body)
    task_id = state.settings.paste.pending_task
    assert is_binary(task_id)
    assert screen(state) =~ "checking the new key"

    failed = %DTO.SettingsTask{
      task_id: task_id,
      action: "search.set_key",
      state: :failed,
      summary: %{"message" => "401 unauthorized"}
    }

    {state, _} = Responses.delta(state, failed)

    assert screen(state) =~
             "The new key was refused (401 unauthorized). s save it anyway · Esc keep the old key"

    {state, effects} = act(state, {:settings, {:verb, :paste_commit}})
    assert sent(effects) == []

    {state, effects} = act(state, {:settings, {:text, "s"}})
    [again] = sent(effects)
    {:settings_command, params} = again.kind
    assert [%{"value" => @canary}] = params["secrets"]
    refute Map.has_key?(params["attributes"], "test_first")
    assert state.settings.paste == nil
    assert clean?(state)
  end
end
