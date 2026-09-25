defmodule SwarmCodeCLI.UI.Settings.Tasks do
  @moduledoc """
  The settings layer's tasks as rows show them (spec §4.9): running with
  its elapsed time and progress, done, failed, timed out, cancelled, and
  whether a task can be stopped. Pure; the entries are the layer's
  `tasks[task_id]` maps (`"action"`, `"state"`, `"elapsed_ms"`,
  `"progress"`, `"message"`, `"received_at_ms"`, `"mine"`).

  Writes are not cancellable once started (the service refuses them); the
  checks, tests, fetches and measures are. Closing the layer cancels the
  cancellable tasks it started; the others keep running and are there on
  the next open.
  """

  @not_cancellable ~w(storage.run storage.vacuum storage.apply_retention import.apply
                      mcp.import.apply provider.apply_models file.save values.reset)

  @doc "Whether a task of `action` can be stopped."
  @spec cancellable?(String.t() | nil) :: boolean()
  def cancellable?(action) when is_binary(action), do: action not in @not_cancellable
  def cancellable?(_action), do: false

  @doc "Whether a task entry is still running."
  @spec running?(map()) :: boolean()
  def running?(task), do: field(task, "state") in [:running, "running"]

  @doc "The running tasks this layer started and may stop."
  @spec to_cancel(map()) :: [String.t()]
  def to_cancel(tasks) do
    for {id, task} <- tasks,
        running?(task),
        field(task, "mine") == true,
        cancellable?(field(task, "action")),
        do: id
  end

  @doc "A task's state as a row shows it, with the time it has run (1 s steps)."
  @spec words(map(), integer()) :: [{String.t(), atom()}]
  def words(task, now) do
    elapsed = elapsed(task, now)

    case field(task, "state") do
      state when state in [:running, "running"] ->
        progress =
          case field(task, "progress") do
            %{"done" => done, "total" => total} -> " · #{done}/#{total}"
            %{done: done, total: total} -> " · #{done}/#{total}"
            _ -> ""
          end

        still = if elapsed >= 30_000, do: " · still running", else: ""
        [{"◷ running · #{seconds(elapsed)}#{progress}#{still}", :info}]

      state when state in [:done, "done"] ->
        [{"✓ done", :success} | message(task)]

      state when state in [:failed, "failed"] ->
        [{"✗ failed", :error} | message(task)]

      state when state in [:timeout, "timeout"] ->
        [{"✗ no answer in #{seconds(elapsed)}", :error}]

      state when state in [:cancelled, "cancelled"] ->
        [{"cancelled", :text_muted}]

      _ ->
        []
    end
  end

  defp message(task) do
    case field(task, "message") do
      text when is_binary(text) and text != "" -> [{" · " <> text, :text_muted}]
      _ -> []
    end
  end

  defp elapsed(task, now) do
    base = field(task, "elapsed_ms") || 0
    received = field(task, "received_at_ms")
    if running?(task) and is_integer(received), do: base + max(now - received, 0), else: base
  end

  defp seconds(ms) when ms < 60_000, do: "#{div(ms, 1_000)} s"
  defp seconds(ms), do: "#{div(ms, 60_000)} min #{rem(div(ms, 1_000), 60)} s"

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil
end
