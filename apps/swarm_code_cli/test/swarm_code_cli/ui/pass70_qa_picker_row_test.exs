defmodule SwarmCodeCLI.UI.Pass70QaPickerRowTest do
  @moduledoc """
  pass70 QA, found driving the release at 120x36: /resume drew a conversation
  with a long first prompt as "Read mix.exs and README … what…  11 runs · o",
  the detail cut at the border mid-word. The title gives way now, so the
  detail that tells conversations apart is always whole.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Init, Keymap, Projector, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}
  alias SwarmCodeCLI.UI.Paint
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  @a "11111111-1111-4111-8111-111111111111"
  @b "22222222-2222-4222-8222-222222222222"

  defp deliver(state, kind, scope, generation, extra, body) do
    delivery =
      struct!(
        %Delivery{
          kind: kind,
          watch_ref: nil,
          request_id: nil,
          scope: scope,
          generation: generation,
          revision: nil,
          sequence: nil,
          body: body
        },
        extra
      )

    elem(Reducer.update(state, {:data, delivery}), 0)
  end

  defp watch_ready(state, slot, body) do
    watch = Map.fetch!(state.watches, slot)

    deliver(
      state,
      :watch_ready,
      watch.scope,
      watch.generation,
      [watch_ref: watch.watch_ref, revision: 0],
      body
    )
  end

  defp ready(columns, rows) do
    size = %Size{columns: columns, rows: rows}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size, color_mode: :truecolor},
        source_epoch: "e",
        destination: {:conversation, @a},
        focus: "composer"
      })

    state
    |> watch_ready(:shell, %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: "e"}
    })
    |> watch_ready(:workspace, %DTO.WorkspaceSnapshot{
      conversation_id: @a,
      allowed_actions: [:send, :queue],
      transcript: %DTO.TranscriptWindow{},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    })
  end

  defp resume(state) do
    {state, _} = Reducer.update(state, {:editor, {@a, :main}, {:insert, "/resume"}})
    intent = {:dispatch, :send, "/resume", :main, []}
    {:ok, action} = Keymap.activate({:intent, intent}, state, %{"send" => {:intent, intent}})
    {state, effects} = Reducer.update(state, action)
    [request] = for {:query, request} <- effects, do: request

    body = %DTO.ConversationList{
      request_id: request.request_id,
      project: "ailogic",
      current_id: @a,
      items: [
        %DTO.ConversationSummary{
          id: @a,
          title:
            "Read mix.exs and README if present; answer in 3 bullets what this project is " <>
              "and which parts of it matter most",
          run_count: 11,
          current: true
        },
        %DTO.ConversationSummary{id: @b, title: "Short one", run_count: 1}
      ]
    }

    deliver(
      state,
      :response,
      request.scope,
      request.generation,
      [request_id: request.request_id],
      body
    )
  end

  defp screen(state) do
    {scene, _table} = Projector.project(state)
    options = %Options{color_mode: :truecolor, ascii?: false}
    {:ok, plan} = Paint.build(scene, options)

    for y <- 0..(plan.size.rows - 1) do
      for x <- 0..(plan.size.columns - 1), into: "" do
        case Plan.cell(plan, x, y) do
          {:glyph, glyph, _, _} -> glyph
          _ -> ""
        end
      end
    end
  end

  for {columns, rows} <- [{120, 36}, {80, 24}] do
    test "a long conversation title leaves its detail whole at #{columns}x#{rows}" do
      state = resume(ready(unquote(columns), unquote(rows)))
      assert Drafts.fetch(state.drafts, {@a, :main}).editor |> SwarmCodeCLI.UI.Editor.text() == ""

      [line] = Enum.filter(screen(state), &String.contains?(&1, "Read mix.exs"))
      assert line =~ "11 runs · open │"
      assert line =~ "…"
    end
  end
end
