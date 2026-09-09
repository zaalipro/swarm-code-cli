import Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

config :swarm_code_daemon,
       :domain_config_dir,
       System.get_env("SWARM_CODE_CONFIG_DIR") ||
         Path.join(System.user_home!(), ".config/swarm-code")
