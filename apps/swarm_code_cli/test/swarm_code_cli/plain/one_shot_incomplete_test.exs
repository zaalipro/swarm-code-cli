defmodule SwarmCodeCLI.Plain.OneShotIncompleteTest do
  @moduledoc """
  Pass 77 C-BUG-9: a headless run whose answer could not be read in full is
  not a clean `0`. A completion read or a detail page that fails (or misses its
  deadline) is asked once more; asked twice without an answer, the command
  exits 1 with the reason `answer_incomplete`, the partial text already
  printed and a sentence in `error`.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.OneShotHarness
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO, Request}

  setup do
    source = start_supervised!({H.Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    %{source: source, output: output, error: error}
  end

  defp summary(context) do
    context.output |> text() |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
  end

  # A page the source could not serve: the typed failure, no reference.
  defp refused, do: %DTO.DetailWindow{state: :error, error: AdmissionError.new(:not_allowed)}

  # The run is done and its answer is longer than its preview: the first ten
  # bytes are in the transcript, the rest is a detail page away.
  defp long_answer(context, format) do
    session = start(context, format: format) |> accept() |> run_update(:done)
    ref = %DTO.DetailRef{id: "detail-1", total_bytes: 19}
    complete(session, [run(:done)], [message("first part", detail_ref: ref)])
    {session, ref}
  end

  defp page_request do
    assert_receive {:source,
                    {:request, :query, %Request{kind: {:query_detail, "detail-1", 10, _}} = page}},
                   5_000

    page
  end

  test "a detail page that fails twice exits 1 with answer_incomplete and keeps the partial text",
       context do
    {session, _ref} = long_answer(context, :json)
    respond(session, page_request(), refused())
    respond(session, page_request(), refused())

    assert code(session) == 1
    summary = summary(context)
    assert summary["reason"] == "answer_incomplete"
    assert summary["exit_code"] == 1
    assert summary["text"] == "first part"
    assert summary["error"] == "the run finished, but its answer could not be read in full."
    assert text(context.error) =~ "the rest of the answer could not be read."
  end

  test "a detail page that fails once and then answers exits 0 with the whole answer", context do
    {session, ref} = long_answer(context, :text)
    respond(session, page_request(), refused())

    respond(session, page_request(), %DTO.DetailWindow{
      detail_ref: ref,
      offset: 10,
      text: " the rest",
      next_offset: nil
    })

    assert code(session) == 0
    assert text(context.output) == "first part the rest\n"
    assert text(context.error) == ""
  end

  test "a completion read that fails twice exits 1 with answer_incomplete", context do
    session = start(context, format: :json) |> accept() |> run_update(:done)

    for _attempt <- 1..2 do
      assert_receive {:source,
                      {:request, :query, %Request{kind: {:query, :workspace, _, _, _, _}} = query}},
                     5_000

      respond(session, query, %DTO.Outcome{
        status: :rejected,
        error: AdmissionError.new(:not_allowed)
      })
    end

    assert code(session) == 1
    summary = summary(context)
    assert summary["reason"] == "answer_incomplete"
    assert summary["state"] == "done"
  end

  test "a completion read that misses its deadline is asked once more", context do
    session = start(context) |> accept() |> run_update(:done)

    assert_receive {:source,
                    {:request, :query, %Request{kind: {:query, :workspace, _, _, _, _}} = first}},
                   5_000

    send(session.owner, {:own_deadline, first.request_id})
    complete(session, [run(:done)], [message("Done anyway.")])

    assert code(session) == 0
    assert text(context.output) == "Done anyway.\n"
  end
end
