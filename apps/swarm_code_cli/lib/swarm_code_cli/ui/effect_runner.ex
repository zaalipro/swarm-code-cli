defmodule SwarmCodeCLI.UI.EffectRunner do
  @moduledoc "Closed effect dispatch. Local ownership stays with the session; admission failures become typed deliveries."
  alias SwarmCodeCLI.UI.Effect
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{Delivery, AdmissionError, DTO}

  def run(effect, context) do
    case Effect.validate(effect) do
      {:ok, valid} -> dispatch(valid, context)
      _ -> :ok
    end
  end

  defp dispatch({:watch, watch}, context) do
    case safely(fn -> DataSource.watch(context.data_source, watch) end) do
      :ok ->
        :ok

      {:error, error} ->
        deliver(context, %Delivery{
          kind: :error,
          watch_ref: watch.watch_ref,
          request_id: nil,
          scope: watch.scope,
          generation: watch.generation,
          revision: nil,
          sequence: nil,
          body: error
        })
    end
  end

  defp dispatch({:query, %{kind: {:resync_watch, ref}} = request}, context) do
    case safely(fn -> DataSource.query(context.data_source, request) end) do
      :ok ->
        :ok

      {:error, error} ->
        deliver(context, %Delivery{
          kind: :error,
          watch_ref: ref,
          request_id: nil,
          scope: request.scope,
          generation: request.generation,
          revision: nil,
          sequence: nil,
          body: error
        })
    end
  end

  defp dispatch({kind, request}, context) when kind in [:query, :command] do
    case safely(fn -> admit(kind, context.data_source, request) end) do
      :ok ->
        :ok

      {:error, error} ->
        deliver(context, %Delivery{
          kind: :response,
          watch_ref: nil,
          request_id: request.request_id,
          scope: request.scope,
          generation: request.generation,
          revision: nil,
          sequence: nil,
          body: error_body(request, error, context.source_epoch)
        })
    end
  end

  defp dispatch({:unwatch, ref}, context),
    do: discard(fn -> DataSource.unwatch(context.data_source, ref) end)

  defp dispatch({:cancel_request, id}, context),
    do: discard(fn -> DataSource.cancel(context.data_source, id) end)

  defp dispatch(effect, context) do
    context.local.(effect)
    :ok
  end

  defp admit(:query, source, request), do: DataSource.query(source, request)
  defp admit(:command, source, request), do: DataSource.command(source, request)

  defp deliver(context, delivery) do
    send(context.owner, {:swarm_code_ui_data, context.source_epoch, delivery})
    :ok
  end

  defp safely(fun) do
    case fun.() do
      :ok ->
        :ok

      {:error, %AdmissionError{} = error} ->
        case AdmissionError.validate(error) do
          {:ok, _} -> {:error, error}
          _ -> {:error, AdmissionError.new(:source_unavailable)}
        end

      _ ->
        {:error, AdmissionError.new(:source_unavailable)}
    end
  catch
    _, _ -> {:error, AdmissionError.new(:source_unavailable)}
  end

  defp discard(fun),
    do:
      (
        safely(fun)
        :ok
      )

  defp error_body(%{expected_response: :outcome} = request, error, _),
    do: %DTO.Outcome{
      request_id: request.request_id,
      status: failure_status(error.code),
      error: error
    }

  # pass74 §3.6: a settings request the data source refused.
  defp error_body(%{expected_response: expected} = request, error, _)
       when expected in [:settings_snapshot, :settings_result],
       do: {:settings_failed, request.request_id, DTO.SettingsResult.failure_words(error)}

  defp error_body(request, error, epoch) do
    attrs = [request_id: request.request_id, state: :error, error: error]

    case request.expected_response do
      :transcript_window ->
        struct!(DTO.TranscriptWindow, attrs)

      :pending_interactions ->
        struct!(DTO.PendingInteractionWindow, attrs)

      :activity_snapshot ->
        struct!(DTO.ActivitySnapshot, attrs ++ [counts: %DTO.Counts{}])

      :shell_snapshot ->
        struct!(
          DTO.ShellSnapshot,
          attrs ++ [counts: %DTO.Counts{}, connection: %DTO.Connection{source_epoch: epoch}]
        )

      :workspace_snapshot ->
        struct!(
          DTO.WorkspaceSnapshot,
          attrs ++
            [
              transcript: %DTO.TranscriptWindow{},
              runs_page: %DTO.PageInfo{},
              interactions_page: %DTO.PageInfo{},
              conversation_id:
                if(request.scope.kind == :conversation, do: request.scope.id, else: nil)
            ]
        )

      :run_detail_snapshot ->
        struct!(DTO.RunDetailSnapshot, attrs ++ [transcript: %DTO.TranscriptWindow{}])

      :detail_window ->
        struct!(DTO.DetailWindow, attrs)

      :library_snapshot ->
        struct!(DTO.LibrarySnapshot, attrs ++ [feature: elem(request.kind, 1)])

      :conversation_list ->
        struct!(DTO.ConversationList, attrs)

      # pass72: the overlay's agent detail (owner S's request).
      :agent_detail ->
        struct!(DTO.AgentDetail, attrs)
    end
  end

  defp failure_status(:stale_revision), do: :revision_conflict
  defp failure_status(:deadline_expired), do: :deadline_exceeded
  defp failure_status(code) when code in [:closed, :source_unavailable], do: :interrupted
  defp failure_status(_), do: :rejected
end
