defmodule SwarmCode.Settings.Registry.Facts do
  @moduledoc false
  # §2.21 Files & environment: facts and checks.
  import SwarmCode.Settings.Registry.Build

  @entries [
    fact("files.cli_json", :files_env, "cli.json", :cli_json,
      description:
        "This terminal's preferences: path, mode (0600), size of 64 KB, unknown keys (kept). ▸ Make it private rewrites it at 0600.",
      synonyms: ["cli.json", "preferences file"],
      since: :c74,
      parity: "NEW"
    ),
    fact("files.database", :files_env, "Database", :database, since: :c74, parity: "NEW"),
    fact("files.config_dir", :files_env, "Config folder", :config_dir, since: :c74, parity: "NEW"),
    fact("files.log", :files_env, "Log", :log,
      description:
        "~/Library/Logs/SwarmCode/cli.log on macOS, $XDG_STATE_HOME/swarm-code/cli.log on Linux.",
      since: :c74,
      parity: "NEW"
    ),
    fact("files.project_dir", :files_env, "This project's .swarm_code/", :project_dir,
      since: :c74,
      parity: "NEW"
    ),
    fact("files.research", :files_env, "Research folder", :research_root,
      since: :c74,
      parity: "NEW"
    ),
    fact("files.user_agents", :files_env, "Your agent definitions", :user_agents,
      since: :c74,
      parity: "NEW"
    ),
    fact("env.variables", :files_env, "Environment", :env,
      description:
        "Every variable SwarmCode reads that is set, its value (secrets say set) and the setting it overrides.",
      synonyms: ["environment variables", "env vars"],
      since: :c74,
      parity: "NEW"
    ),
    fact("launch.summary", :files_env, "This launch", :launch,
      description: "Flags, conversation and project of this launch.",
      since: :c74,
      parity: "NEW"
    ),
    fact("terminal.this_terminal", :files_env, "This terminal", :terminal,
      description:
        "Size, colour mode, glyph tier, ambiguous width, paste, focus, wheel, enhanced keys, TERM, TERM_PROGRAM.",
      since: :c74,
      parity: "NEW"
    ),
    fact("files.versions", :files_env, "Versions", :versions,
      description: "CLI version, service version, protocol body version, OTP, Elixir.",
      synonyms: ["version"],
      since: :c74,
      parity: "NEW"
    ),
    action("files.doctor", :files_env, "Check everything", "doctor",
      description:
        "Database, folders, providers, MCP, search, the project file, cli.json and the log.",
      synonyms: ["doctor", "check"],
      since: :c74,
      parity: "NEW"
    )
  ]

  def entries, do: @entries
end
