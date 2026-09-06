defmodule Mix.Tasks.Compile.SchemaSnapshot do
  use Mix.Task.Compiler
  @recursive true
  @impl true
  def run(args) do
    root = Path.dirname(Mix.Project.project_file())
    source = Path.expand("../../native/schema_snapshot/main.c", root)
    destination = Path.join(root, "priv/native/swarm-schema-snapshot")
    stamp_path = destination <> ".platform"

    platform =
      "schema-snapshot-v1\n#{inspect(:os.type())}\n#{:erlang.system_info(:system_architecture)}\n"

    if "--force" in args or File.read(stamp_path) != {:ok, platform} or
         Mix.Utils.stale?([source, Mix.Project.project_file()], [destination]) do
      compiler = System.find_executable("cc") || Mix.raise("A C compiler is required")
      File.mkdir_p!(Path.dirname(destination))
      temporary = destination <> ".#{System.unique_integer([:positive])}.tmp"

      try do
        {output, status} =
          System.cmd(
            compiler,
            ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", source, "-o", temporary],
            stderr_to_stdout: true
          )

        if status != 0, do: Mix.raise("Schema snapshot helper compilation failed:\n" <> output)
        File.chmod!(temporary, 0o755)
        File.rename!(temporary, destination)
        File.write!(temporary, platform)
        File.rename!(temporary, stamp_path)
        {:ok, []}
      after
        File.rm(temporary)
      end
    else
      {:noop, []}
    end
  end
end

defmodule SwarmCodeDaemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :swarm_code_daemon,
      version: "0.1.0-dev",
      elixir: "~> 1.18.4",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      compilers: [:schema_snapshot] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:swarm_code_core, in_umbrella: true},
      {:ecto_sql, "== 3.14.0"},
      {:ecto_sqlite3, "== 0.24.1"},
      {:exqlite, "== 0.39.0"},
      {:jason, "== 1.4.5"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
