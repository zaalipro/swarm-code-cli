defmodule Mix.Tasks.Compile.SchemaSnapshot do
  use Mix.Task.Compiler
  @recursive true
  @impl true
  def run(args) do
    root = Path.dirname(Mix.Project.project_file())

    results =
      for {directory, executable} <- [
            {"schema_snapshot", "swarm-schema-snapshot"},
            {"tool_command", "swarm-tool-command"}
          ] do
        build(root, directory, executable, args)
      end

    results = [build_platform(root, args) | results]
    if Enum.any?(results, &(&1 == :built)), do: {:ok, []}, else: {:noop, []}
  end

  defp build_platform(root, args) do
    if :os.type() == {:unix, :darwin} do
      source = Path.expand("../../native/platform_identity/main.m", root)
      destination = Path.join(root, "priv/native/swarm-macos-helper")

      if "--force" in args or
           Mix.Utils.stale?([source, Mix.Project.project_file()], [destination]) do
        temporary = destination <> ".#{System.unique_integer([:positive])}.tmp"
        File.mkdir_p!(Path.dirname(destination))

        try do
          {output, status} =
            System.cmd(
              "/usr/bin/clang",
              [
                "-Wall",
                "-Wextra",
                "-Werror",
                "-O2",
                "-fobjc-arc",
                "-framework",
                "AppKit",
                source,
                "-o",
                temporary
              ],
              stderr_to_stdout: true
            )

          if status != 0, do: Mix.raise("macOS helper compilation failed:\n" <> output)
          # Source builds are internal artifacts; release builds must re-sign
          # with Developer ID before compiling the Elixir helper digest.
          identity = System.get_env("SWARM_MACOS_SIGN_IDENTITY", "-")

          {output, status} =
            System.cmd(
              "/usr/bin/codesign",
              [
                "--force",
                "--sign",
                identity,
                "--identifier",
                "com.zaali.swarmcode.cli.platform",
                temporary
              ],
              stderr_to_stdout: true
            )

          if status != 0, do: Mix.raise("macOS helper signing failed:\n" <> output)
          File.chmod!(temporary, 0o755)
          File.rename!(temporary, destination)
          :built
        after
          File.rm(temporary)
        end
      else
        :unchanged
      end
    else
      :unchanged
    end
  end

  defp build(root, directory, executable, args) do
    source = Path.expand("../../native/#{directory}/main.c", root)
    destination = Path.join(root, "priv/native/#{executable}")
    stamp_path = destination <> ".platform"

    platform =
      "#{executable}-v1\n#{inspect(:os.type())}\n#{:erlang.system_info(:system_architecture)}\n"

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

        if status != 0, do: Mix.raise("#{executable} compilation failed:\n" <> output)
        File.chmod!(temporary, 0o755)
        File.rename!(temporary, destination)
        File.write!(temporary, platform)
        File.rename!(temporary, stamp_path)
        :built
      after
        File.rm(temporary)
      end
    else
      :unchanged
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
    [mod: {SwarmCode.Daemon.Application, []}, extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:swarm_code_core, in_umbrella: true},
      {:ecto_sql, "== 3.14.0"},
      {:ecto_sqlite3, "== 0.24.1"},
      {:exqlite, path: "../../vendor/exqlite", override: true, env: Mix.env()},
      {:req, "== 0.7.3"},
      {:jason, "== 1.4.5"},
      {:earmark, "== 1.4.49"},
      {:floki, "== 0.38.4"},
      {:html_sanitize_ex, "== 1.5.5"},
      {:tzdata, "== 1.1.4"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
