defmodule SwarmCode.Daemon.Service.Settings.Efforts do
  @moduledoc """
  A provider's reasoning-effort levels in settings (pass 74 §3.5.1): the
  effort-levels table saved as one draft (`efforts.save`, provider scope or one
  model's override), the removal of a model's override, and the presets.

  The rows are checked by the domain's `Efforts.from_rows/1`, so a row error is
  the desktop's exact text, keyed `rows[i]`.
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  alias SwarmCode.Daemon.Service.Settings.Kit
  alias SwarmCode.Daemon.Service.Settings.Providers, as: ProviderSettings
  alias SwarmCode.Domain.{Providers, Repo}
  alias SwarmCode.Domain.LLM.Efforts, as: Levels
  alias SwarmCode.Domain.Providers.Provider

  @max_rows 32

  @doc false
  def actions, do: ~w(efforts.save efforts.remove_override)

  @doc false
  def views, do: [{"records", "effort_presets"}]

  @doc false
  def cache_reads(_action_or_view), do: []

  @doc false
  def query("records", "effort_presets", params, _ctx) do
    kind = Kit.get(Kit.options(params), "kind")

    items =
      for preset <- Levels.presets(), is_nil(kind) or kind in preset.kinds do
        Kit.record("effort_preset", preset.id, %{
          "id" => preset.id,
          "name" => preset.name,
          "kinds" => preset.kinds,
          "levels" => preset.levels
        })
      end

    {:ok, Kit.records_body("effort_preset", items, params)}
  end

  def query(_view, _kind, _params, _ctx), do: unsupported()

  @doc false
  def command(%{action: "efforts.save"} = cmd, ctx) do
    target = Kit.cmd(cmd, :target)
    rows = Kit.get(Kit.cmd(cmd, :attributes), "rows")

    with {:ok, expected} <- expected(cmd),
         {:ok, rows} <- rows(rows),
         {:ok, levels} <- from_rows(rows) do
      model = Kit.get(target, "model")

      save(Kit.get(target, "id"), model, expected, cmd, ctx, fn fresh ->
        put_levels(fresh, model, levels)
      end)
    end
  end

  def command(%{action: "efforts.remove_override"} = cmd, ctx) do
    target = Kit.cmd(cmd, :target)
    model = Kit.get(target, "model")

    with {:ok, expected} <- expected(cmd) do
      if is_binary(model) and model != "" do
        save(Kit.get(target, "id"), model, expected, cmd, ctx, fn fresh ->
          %{"model_effort_levels" => Map.delete(fresh.model_effort_levels || %{}, model)}
        end)
      else
        Kit.error(:invalid, "name the model whose override to remove")
      end
    end
  end

  def command(_cmd, _ctx), do: unsupported()

  # The rows as `Efforts.from_rows/1` reads a form: `body` as JSON text,
  # `drop` as a comma list.
  defp rows(rows) when is_list(rows) and length(rows) <= @max_rows do
    if Enum.all?(rows, &is_map/1),
      do: {:ok, Enum.map(rows, &form_row/1)},
      else: Kit.error(:invalid, "every level must be an object")
  end

  defp rows(rows) when is_list(rows),
    do:
      Kit.error(:invalid, "#{@max_rows} levels at most", [
        Kit.field_error("rows", "#{@max_rows} levels at most")
      ])

  defp rows(_rows), do: Kit.error(:invalid, "rows must be a list of levels")

  defp form_row(row) do
    %{
      "key" => Kit.get(row, "key"),
      "label" => Kit.get(row, "label"),
      "hint" => Kit.get(row, "hint"),
      "body" => body_text(Kit.get(row, "body")),
      "drop" => drop_text(Kit.get(row, "drop"))
    }
  end

  defp body_text(nil), do: ""
  defp body_text(text) when is_binary(text), do: text
  defp body_text(other), do: Jason.encode!(other)

  defp drop_text(list) when is_list(list), do: list |> Enum.map(&to_string/1) |> Enum.join(", ")
  defp drop_text(text) when is_binary(text), do: text
  defp drop_text(_other), do: ""

  defp from_rows(rows) do
    case Levels.from_rows(rows) do
      {:ok, levels} ->
        {:ok, levels}

      {:error, errors} ->
        field_errors =
          errors
          |> Enum.sort()
          |> Enum.map(fn {i, message} -> Kit.field_error("rows[#{i}]", message) end)

        [%{target: target, message: message} | _] = field_errors
        Kit.error(:invalid, "#{target}: #{message}", field_errors)
    end
  end

  defp put_levels(_fresh, model, levels) when model in [nil, ""],
    do: %{"effort_levels" => if(levels == [], do: nil, else: levels)}

  defp put_levels(fresh, model, levels) do
    overrides = fresh.model_effort_levels || %{}

    %{
      "model_effort_levels" =>
        if(levels == [],
          do: Map.delete(overrides, model),
          else: Map.put(overrides, model, levels)
        )
    }
  end

  defp current(fresh, model) when model in [nil, ""], do: fresh.effort_levels
  defp current(fresh, model), do: Map.get(fresh.model_effort_levels || %{}, model)

  defp save(id, model, expected, cmd, ctx, change) do
    outcome =
      Repo.retry(:settings_efforts, fn ->
        Repo.transaction(fn ->
          fresh = Repo.get(Provider, id || "") || Repo.rollback(:not_found)
          levels = current(fresh, model)

          cond do
            not Kit.same?(expected, levels) ->
              Repo.rollback({:conflict, fresh, levels})

            Map.get(cmd, :dry_run) ->
              {:unchanged, fresh}

            true ->
              attrs = change.(fresh)

              if Enum.all?(attrs, fn {k, v} ->
                   Kit.same?(v, Map.get(fresh, String.to_existing_atom(k)))
                 end) do
                {:unchanged, fresh}
              else
                case Providers.update(fresh, attrs) do
                  {:ok, provider} -> {:updated, provider}
                  {:error, changeset} -> Repo.rollback({:invalid, changeset})
                end
              end
          end
        end)
      end)

    case outcome do
      {:ok, {:updated, provider}} ->
        Providers.broadcast()
        Kit.ok(record: ProviderSettings.record(provider, ctx), message: "Reasoning effort saved")

      {:ok, {:unchanged, fresh}} ->
        Kit.ok(:unchanged, record: ProviderSettings.record(fresh, ctx))

      {:error, {:conflict, fresh, levels}} ->
        Kit.ok(:conflict,
          results: [Kit.row("levels", :conflict, current: levels)],
          record: ProviderSettings.record(fresh, ctx),
          message: "#{fresh.name}'s effort levels changed while you edited them."
        )

      {:error, {:invalid, changeset}} ->
        Kit.changeset_error(changeset)

      {:error, :not_found} ->
        Kit.error(:not_found, "That provider no longer exists.")

      {:error, _other} ->
        Kit.error(:busy, "Settings is busy; try again in a moment.")
    end
  end

  defp expected(cmd) do
    expected = Kit.cmd(cmd, :expected)

    if Kit.has?(expected, "levels"),
      do: {:ok, Kit.get(expected, "levels")},
      else: Kit.error(:invalid, "expected is missing for levels")
  end

  defp unsupported,
    do: Kit.error(:unsupported, "This part of settings is not available in this build.")
end
