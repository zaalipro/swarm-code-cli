defmodule SwarmCodeCLI.Cli020.E12TurnHeaderTest do
  # cli020 E12 (ux-live-23, ux-live-3): the header says `writing` from the
  # first content delta, `retrying 2/5 · HTTP 500` from the run's retry
  # detail (C5), a failure is printed once, and a refused connection reads
  # as such.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Pass73Helpers, as: H

  defp chat(run_state, items, run_fields \\ %{}) do
    run = struct!(%{H.run("s", run_state) | created_sequence: 1}, run_fields)

    items = [
      item("u", role: :user, text: "Review the router", node_id: "s", state: :done)
      | items
    ]

    H.ready([run],
      columns: 120,
      rows: 30,
      snapshot: %{transcript: %DTO.TranscriptWindow{items: items}}
    )
  end

  defp header(state), do: state |> screen() |> Enum.find(&(&1 =~ "Assistant"))

  test "writing as soon as the answer has words, even while its step is the same text" do
    words = "Streaming word 1 word 2"

    state =
      chat(:streaming, [
        item("step",
          kind: :thinking,
          agent_id: "lead",
          node_id: "step",
          text: words,
          state: :streaming
        ),
        item("answer", agent_id: nil, node_id: "s", text: words, state: :streaming)
      ])

    assert header(state) =~ "writing"
    refute header(state) =~ "thinking"
  end

  test "thinking before the first word" do
    state = chat(:streaming, [item("answer", node_id: "s", text: "", state: :streaming)])
    assert header(state) =~ "thinking"
  end

  test "the retry detail replaces thinking" do
    state =
      chat(:retrying, [item("answer", node_id: "s", text: "", state: :streaming)])
      |> then(fn st ->
        runs =
          Map.new(st.read_model.runs, fn {id, r} ->
            {id, Map.put(r, :retry_detail, "retrying 2/5 · HTTP 500")}
          end)

        put_in(st.read_model.runs, runs)
      end)

    assert header(state) =~ "retrying 2/5 · HTTP 500"
    refute header(state) =~ "thinking"
  end

  @failure "127.0.0.1 request failed after 5 attempts: HTTP 500"

  test "a failed run prints its error once" do
    state =
      chat(:failed, [item("err", kind: :error, node_id: "s", text: @failure, state: :failed)], %{
        error: @failure
      })

    text = screen_text(state)
    assert length(String.split(text, "request failed after 5 attempts")) - 1 == 1, text
    assert text =~ "Failed · " <> @failure
  end

  test "econnrefused reads as a refused connection" do
    error = "%Req.TransportError{reason: :econnrefused}"

    state =
      chat(:failed, [item("err", kind: :error, node_id: "s", text: error, state: :failed)], %{
        error: error
      })

    text = screen_text(state)
    assert text =~ "Cannot connect to the provider (connection refused)."
    refute text =~ "econnrefused"
    refute text =~ "connection dropped"
  end
end
