defmodule SwarmCodeCLI.UI.Settings.C74SafetyTest do
  @moduledoc """
  cli74 U1-18: the settings layer's performance and safety bounds — no timer
  while nothing moves (browsing, searching, the command line, closing), one
  timer per write or stepped number and none after it settles, and the
  settings code (layer, reducer, projector) free of detached work, IO,
  runtime atoms and any path to the daemon or the database. The search
  bound (< 20 ms over 8 000 entries) is in `C74SearchTest`; the UI → daemon
  boundary for every UI file stays in `ArchitectureTest`.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCodeCLI.UI.{Input, Keymap, Reducer, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Settings.Nav

  @ui Path.expand("../../../../lib/swarm_code_cli/ui", __DIR__)

  defp sent(effects),
    do: for({kind, %Request{} = request} <- effects, kind in [:query, :command], do: request)

  # Runs `actions` (Reducer actions, or `{:key, input}` pressed through the
  # keymap), answering every settings request from the fake store; returns
  # the state and every effect in order.
  defp drive(state, actions, fake \\ FakeSettings.seed()) do
    Enum.reduce(actions, {state, [], fake}, fn action, {state, seen, fake} ->
      {state, effects} = step(state, action)
      {state, more, fake} = answer(state, effects, fake)
      {state, seen ++ effects ++ more, fake}
    end)
  end

  defp step(state, {:key, input}) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> Reducer.update(state, action)
      :ignore -> {state, []}
    end
  end

  defp step(state, action), do: Reducer.update(state, action)

  defp answer(state, effects, fake) do
    case sent(effects) do
      [] ->
        {state, [], fake}

      requests ->
        {state, more, fake} =
          Enum.reduce(requests, {state, [], fake}, fn request, {acc, more, fake} ->
            {fake, body, _facts} =
              case request.kind do
                {:settings_query, _} -> FakeSettings.query(fake, request)
                {:settings_command, _} -> FakeSettings.command(fake, request)
              end

            {acc, next} = Reducer.update(acc, {:data, delivery(request, body)})
            {acc, more ++ next, fake}
          end)

        {state, deeper, fake} = answer(state, more, fake)
        {state, more ++ deeper, fake}
    end
  end

  defp delivery(request, body),
    do: %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: body
    }

  defp timers(effects), do: for({:start_timer, _, _, _} = timer <- effects, do: timer)
  defp key(name), do: {:key, Input.key(name)}

  defp text(letters),
    do: for(l <- String.graphemes(letters), do: {:key, Input.text_fragment(:press, l, [])})

  defp sized, do: elem(Reducer.update(ready(), {:resize, %Size{columns: 160, rows: 45}}), 0)

  describe "timers" do
    test "browsing, searching, the command line and closing start none, and nothing ticks" do
      actions =
        [{:settings_open, nil}, key(:down), key(:down), key(:up), key(:end), key(:home)] ++
          [{:settings, {:verb, :next_section}}, {:settings, {:verb, :next_section}}] ++
          [key(:down), key(:down)] ++
          text("/") ++
          text("timeout") ++
          [key(:escape), key(:escape)] ++
          text(":") ++
          text("get terminal.panel") ++
          [key(:enter)] ++
          [{:settings, {:verb, :previous_section}}, {:settings_open, {:section, :storage}}]

      {state, effects, _fake} = drive(sized(), actions)
      assert state.settings.search == nil and state.settings.mode == :browse
      assert sent(effects) != [] and state.settings.status.text == "terminal.panel = full"
      assert timers(effects) == []

      later = %{state | now: state.now + 60_000}
      refute SessionRuntime.time_dependent?(later)

      {closed, effects, _fake} = drive(later, [key(:escape), {:settings_open, nil}])
      assert timers(effects) == []
      assert Nav.current(closed) != nil
    end

    test "a write starts one saving timer; a stepped number one settle timer" do
      {state, _, fake} = drive(sized(), [{:settings_open, {:key, "terminal.panel"}}])
      {_state, effects, _} = drive(state, [{:settings, {:verb, :right}}], fake)
      assert [{:start_timer, _, 300, {:settings, {:saving, _, _}}}] = timers(effects)

      {state, _, fake} = drive(sized(), [{:settings_open, {:key, "terminal.composer_rows"}}])
      {_state, effects, _} = drive(state, [{:settings, {:verb, :right}}], fake)
      assert [{:start_timer, _, 600, {:settings, {:settle, _, _}}}] = timers(effects)
    end
  end

  describe "the settings code" do
    defp sources do
      [
        Path.wildcard(Path.join(@ui, "settings/**/*.ex")),
        Path.wildcard(Path.join(@ui, "reducer/settings/**/*.ex")),
        [Path.join(@ui, "reducer/settings.ex"), Path.join(@ui, "projector/settings.ex")],
        Path.wildcard(Path.join(@ui, "projector/settings/**/*.ex"))
      ]
      |> Enum.concat()
      |> Enum.uniq()
    end

    defp offenders(pattern) do
      for path <- sources(),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          Regex.match?(pattern, line),
          do: "#{Path.relative_to(path, @ui)}:#{n}: #{String.trim(line)}"
    end

    test "the sources are there to scan" do
      assert length(sources()) > 40
    end

    test "no detached or unowned work: no Task.start/async, spawn, send_after or :timer" do
      assert offenders(~r/\bTask\.(start|async)|\bspawn(_link)?\(|Process\.send_after|:timer\./) ==
               []
    end

    test "no IO in the layer, its reducer or its projector" do
      assert offenders(
               ~r/(?<![A-Za-z])File\.[a-z_]+\(|\bIO\.[a-z_]+\(|System\.(cmd|get_env|put_env|shell)|:os\.|Port\.open/
             ) == []
    end

    test "no atom made from runtime text" do
      assert offenders(~r/String\.to_atom|:erlang\.binary_to_atom|List\.to_atom/) == []
    end

    test "no path to the daemon or the database" do
      assert offenders(
               ~r/SwarmCode\.Repo|SwarmCode\.Daemon|\bEcto\.|Exqlite|SwarmCode\.Conversations/
             ) ==
               []
    end

    test "the UI never loads code by name" do
      assert offenders(~r/Code\.ensure_(loaded|compiled)|Module\.concat|:code\.|\bapply\(/) == []
    end
  end
end
