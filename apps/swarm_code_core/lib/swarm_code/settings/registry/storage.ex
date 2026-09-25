defmodule SwarmCode.Settings.Registry.Storage do
  @moduledoc false
  # §2.18 Storage: retention policies, the last sweep and the actions.
  import SwarmCode.Settings.Registry.Build

  @entries [
    global("storage.retention_days", :storage, "Automatically delete sessions older than",
      group: "retention",
      description:
        "The desktop app's daily sweep applies it, or ▸ Apply retention now. Pinned sessions, open sessions and anything still running are never touched.",
      storage: {:setting, :storage_retention_days},
      type: :integer,
      unit: :days,
      min: 7,
      max: 3650,
      big_step: 30,
      nullable: true,
      null_label: "off",
      applies: :desktop,
      scheduler_only: true,
      shared: true,
      synonyms: ["retention", "delete old sessions"],
      parity: "D§8b"
    ),
    global("storage.prune_days", :storage, "Prune agent details older than",
      group: "retention",
      description:
        "Keeps transcripts, tokens, cost and timings; only tool output and prompts go.",
      storage: {:setting, :storage_prune_days},
      type: :integer,
      unit: :days,
      min: 7,
      max: 3650,
      big_step: 30,
      nullable: true,
      null_label: "off",
      applies: :desktop,
      scheduler_only: true,
      shared: true,
      synonyms: ["prune"],
      parity: "D§8b"
    ),
    fact("storage.last_sweep", :storage, "Last sweep", :storage_last_cleanup_at,
      group: "retention",
      stored_name: "storage_last_cleanup_at",
      parity: "D§8b"
    ),
    action("storage.measure", :storage, "Measure", "storage.measure",
      description:
        "Runs when the page opens if no measure ran this session: overview, quick-preset previews, sessions list.",
      parity: "D§8a"
    ),
    action("storage.cleanup", :storage, "Clean up…", "storage.plan",
      description: "Choose what to delete or prune, review it, then run it. Not undoable.",
      synonyms: ["cleanup", "clean up"],
      parity: "D§8c"
    ),
    action("storage.vacuum", :storage, "Reclaim disk space (VACUUM)", "storage.vacuum",
      description: "Rewrites the database file; deletes nothing.",
      synonyms: ["vacuum"],
      parity: "D§8c"
    ),
    action("storage.apply_retention", :storage, "Apply retention now", "storage.apply_retention",
      group: "retention",
      description: "The desktop app normally does this daily.",
      since: :c74,
      parity: "NEW (D27)"
    )
  ]

  def entries, do: @entries
end
