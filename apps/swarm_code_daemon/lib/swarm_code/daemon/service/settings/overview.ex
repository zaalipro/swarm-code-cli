defmodule SwarmCode.Daemon.Service.Settings.Overview do
  @moduledoc """
  The `overview` view (pass 74, spec §3.3.6, §2.1): what needs attention — S1's
  own items (AT4, AT16, AT18 from the values; AT10 no provider can answer; AT11
  retention has not run) and every loaded handler's `attention/1` — errors first,
  then warnings, then rail order, at most 64; and the glance fragments (S1:
  agents, approvals, budget; the handlers: providers, search, MCP, storage).

  A handler that raises is skipped with a log line naming it; the overview never
  fails for one section.
  """
  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  require Logger

  alias SwarmCode.Daemon.Service.SessionConfiguration
  alias SwarmCode.Daemon.Service.Settings.{Context, Error, Router, Usage, Values}
  alias SwarmCode.Domain.Providers
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Settings.Sections

  @max 64
  @stale_days 7
  @severity %{"error" => 0, "warning" => 1, "info" => 2}

  @impl true
  def actions, do: []

  @impl true
  def command(_command, _ctx), do: {:error, Error.unsupported()}

  @impl true
  def views, do: [{"overview", nil}]

  @impl true
  def query("overview", _kind, _params, %Context{} = ctx), do: {:ok, body(ctx)}
  def query(_view, _kind, _params, _ctx), do: {:error, Error.unsupported()}

  @doc "The overview body."
  @spec body(Context.t()) :: map()
  def body(%Context{} = ctx) do
    %{"attention" => attention_items(ctx), "glance" => glance_fragments(ctx)}
  end

  @doc "Every attention item, sorted and capped."
  @spec attention_items(Context.t()) :: [map()]
  def attention_items(ctx) do
    own = guarded(Values, fn -> Values.attention(ctx) end, []) ++ at10() ++ at11()

    handlers =
      for module <- handler_modules(), function_exported?(module, :attention, 1) do
        guarded(module, fn -> module.attention(ctx) end, [])
      end

    finish(own ++ List.flatten(handlers))
  end

  @doc """
  One item per id and target, with string keys, sorted, at most 64. The
  handlers' items have atom keys and share their source's id (`AT1` for every
  failed server): read as `item["id"]` they were all `nil`, so every handler
  item after the first was dropped (QA F-9: a failed MCP server behind a
  pricing item was never counted).
  """
  @spec finish([map()]) :: [map()]
  def finish(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify/1)
    |> Enum.uniq_by(&{&1["id"], &1["target"]})
    |> sort()
    |> Enum.take(@max)
  end

  defp stringify(item), do: Map.new(item, fn {key, value} -> {to_string(key), value} end)

  @doc "Errors first, then warnings, then the rail order of their sections (stable)."
  @spec sort([map()]) :: [map()]
  def sort(items) do
    rail = Sections.id_strings()

    Enum.sort_by(items, fn item ->
      {Map.get(@severity, item["severity"], 3),
       Enum.find_index(rail, &(&1 == item["section"])) || length(rail)}
    end)
  end

  # AT10: no provider can answer, or the chat default's provider has no key.
  defp at10 do
    providers = Providers.list()

    cond do
      not Enum.any?(providers, &SessionConfiguration.usable?/1) ->
        [
          item(
            "no_provider",
            "error",
            "providers",
            %{"kind" => "providers", "id" => nil},
            "No provider can answer",
            "add a key or a local server"
          )
        ]

      (provider = chat_default_provider()) != nil and not SessionConfiguration.usable?(provider) ->
        [
          item(
            "chat_provider_keyless",
            "error",
            "models_effort",
            %{"key" => "models.chat"},
            "The chat model's provider #{provider.name} has no key",
            "add a key or a local server"
          )
        ]

      true ->
        []
    end
  end

  # The provider new conversations use; never on a missing settings row (D24).
  defp chat_default_provider do
    if Values.settings_row() do
      case Providers.effective_model(%Conversation{}, :chat) do
        {:ok, %{provider: provider}} -> provider
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  # AT11: a retention policy is set and the sweep has not run for a week.
  defp at11 do
    case Values.settings_row() do
      %{storage_retention_days: r, storage_prune_days: p} = row when r != nil or p != nil ->
        days =
          case row.storage_last_cleanup_at do
            nil -> nil
            at -> DateTime.diff(DateTime.utc_now(), at, :day)
          end

        if days == nil or days > @stale_days do
          title =
            if days,
              do: "Retention has not run for #{days} days",
              else: "Retention has never run"

          [
            item(
              "retention_stale",
              "warning",
              "storage",
              %{"key" => "storage.retention_days"},
              title,
              "it runs in the desktop app · ▸ apply now"
            )
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp item(id, severity, section, target, title, reason),
    do: %{
      "id" => id,
      "severity" => severity,
      "section" => section,
      "target" => target,
      "title" => title,
      "reason" => reason
    }

  @doc "The glance fragments: S1's and every loaded handler's."
  @spec glance_fragments(Context.t()) :: map()
  def glance_fragments(ctx) do
    own = guarded(__MODULE__, fn -> own_glance(ctx) end, %{})

    for module <- handler_modules(), function_exported?(module, :glance, 1), reduce: own do
      acc ->
        case guarded(module, fn -> module.glance(ctx) end, %{}) do
          fragments when is_map(fragments) -> Map.merge(acc, bounded(fragments))
          _ -> acc
        end
    end
  end

  defp own_glance(ctx) do
    row = Values.settings_row() || %SwarmCode.Domain.Settings.Setting{}
    project = ctx.project && SwarmCode.Domain.Projects.get(ctx.project.id)

    %{
      "agents" => %{
        "max_concurrent" => row.max_concurrent_agents,
        "max_depth" => row.max_agent_depth,
        "max_turns" => row.max_agent_turns,
        "sub_agent_timeout_s" => row.sub_agent_timeout_s
      },
      "approvals" =>
        if(project,
          do: %{
            "project" => project.name,
            "mode" => project.approval_mode,
            "trusted" => project.trusted_at != nil,
            "allowed" => length(project.auto_approve_prefixes || [])
          },
          else: %{}
        ),
      "budget" => %{
        "spend_usd" => Usage.month_spend(),
        "budget_usd" => row.monthly_budget_usd
      }
    }
  end

  defp bounded(fragments) do
    for {name, fragment} <- fragments, is_binary(name) and is_map(fragment), into: %{} do
      {name, fragment |> Enum.take(16) |> Map.new()}
    end
  end

  # Loaded handlers with attention or glance, S1's own excluded.
  defp handler_modules do
    Router.loaded_modules() -- [Values, __MODULE__]
  end

  defp guarded(module, fun, fallback) do
    fun.()
  rescue
    _ ->
      Logger.warning("settings overview skipped #{inspect(module)}")
      fallback
  catch
    :exit, _ ->
      Logger.warning("settings overview skipped #{inspect(module)}")
      fallback
  end
end
