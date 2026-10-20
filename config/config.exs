import Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

# pass 77 D-ARCH-11: the module the engine's synced notifier (`Engine.Notifier`,
# desktop pass 77) reads to tell the user a run waits or finished, instead of
# calling `SwarmCode.Desktop` directly. The CLI's is its own
# `SwarmCode.Domain.Notifications` (`notify_waiting/1`, `notify_finished/1`).
config :swarm_code_daemon, :engine_notifier, SwarmCode.Domain.Notifications

# The global SwarmCode directory is resolved at run time by
# `SwarmCode.Domain.Paths.config_dir/0` (never baked into a release's
# sys.config). Tests get a private scratch directory unless a test sets its own.
if config_env() == :test do
  config :swarm_code_daemon,
         :domain_config_dir,
         Path.join(System.tmp_dir!(), "swarm-code-test-config-#{System.get_env("USER", "user")}")

  # pass75: no AI status lines in tests unless a test turns them on.
  config :swarm_code_daemon, :summarize_agents, false
end
