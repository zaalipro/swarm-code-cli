defmodule SwarmCode.Daemon.Service.R1019DeltaRoutesTest do
  @moduledoc """
  Pass 77 C-ARCH-2: `PersistedBackend.broadcast/2` routes a delta kind to watch
  slots by one table (`@routes`). The golden test holds the table to the four
  per-slot lists it replaced; the source scan makes a new delta kind an
  explicit decision.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Service.PersistedBackend

  @slots ~w(shell activity workspace inspector transcript pending)

  # The rules as they stood before the table (pass 70 C1/C6, pass 74 S1-10).
  defp reference(slot, kind) do
    settings? = kind in ["settings_update", "settings_task"]

    case slot do
      "shell" ->
        kind in [
          "run_update",
          "toast",
          "rate_limit",
          "settings_update",
          "settings_task",
          "desktop_running",
          "vitals",
          "elsewhere",
          "home_stale"
        ]

      _other when settings? ->
        false

      "activity" ->
        kind == "activity_upsert"

      "workspace" ->
        kind not in [
          "activity_upsert",
          "toast",
          "rate_limit",
          "desktop_running",
          "vitals",
          "elsewhere",
          "home_stale"
        ]

      "inspector" ->
        kind not in [
          "activity_upsert",
          "workspace_metadata",
          "toast",
          "rate_limit",
          "desktop_running",
          "vitals",
          "elsewhere",
          "home_stale"
        ]

      _transcript_or_pending ->
        kind not in [
          "activity_upsert",
          "workspace_metadata",
          "toast",
          "rate_limit",
          "background_upsert",
          "background_remove",
          "desktop_running",
          "vitals",
          "elsewhere",
          "home_stale",
          "shell_upsert",
          "shell_remove"
        ]
    end
  end

  test "every listed kind reaches exactly the slots the old rules gave it" do
    kinds = Enum.uniq(Map.keys(PersistedBackend.routes()) ++ ["node_upsert", "not_listed_kind"])

    for kind <- kinds, slot <- @slots do
      assert PersistedBackend.routed?(slot, kind) == reference(slot, kind),
             "slot #{slot} and kind #{kind} route differently from the old rules"
    end
  end

  test "a kind that is not listed is scoped" do
    for slot <- ~w(workspace inspector transcript pending) do
      assert PersistedBackend.routed?(slot, "not_listed_kind")
    end

    refute PersistedBackend.routed?("shell", "not_listed_kind")
    refute PersistedBackend.routed?("activity", "not_listed_kind")
  end

  @service_dir Path.expand("../../../../lib/swarm_code/daemon/service", __DIR__)

  test "every kind the backend and the projection name is in the table" do
    sources =
      for file <- ~w(persisted_backend.ex persisted_projection.ex settings/deltas.ex) do
        File.read!(Path.join(@service_dir, file))
      end

    literal = for s <- sources, [_, k] <- Regex.scan(~r/"kind" => "([a-z_]+)"/, s), do: k

    helper =
      for s <- sources,
          [_, k] <- Regex.scan(~r/\b(?:delta|entity_delta|shell_delta)\("([a-z_]+)"/, s),
          do: k

    kinds = Enum.uniq(literal ++ helper)
    assert length(kinds) > 20

    unlisted = kinds -- Map.keys(PersistedBackend.routes())
    assert unlisted == [], "kinds missing from @routes: #{inspect(unlisted)}"
  end
end
