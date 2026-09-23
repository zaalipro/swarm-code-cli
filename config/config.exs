import Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

# The global SwarmCode directory is resolved at run time by
# `SwarmCode.Domain.Paths.config_dir/0` (never baked into a release's
# sys.config). Tests get a private scratch directory unless a test sets its own.
if config_env() == :test do
  config :swarm_code_daemon,
         :domain_config_dir,
         Path.join(System.tmp_dir!(), "swarm-code-test-config-#{System.get_env("USER", "user")}")
end
