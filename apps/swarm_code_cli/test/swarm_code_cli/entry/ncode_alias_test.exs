defmodule SwarmCodeCLI.Release.NcodeAliasTest do
  @moduledoc """
  ncode rename (lane A): the command is `bin/ncode`; `bin/swarmcode` and
  `bin/swarm-code` are deprecated names that run it. `NCODE_*` names are read
  first and the older `SWARM_*` names are the fallback: the launcher copies an
  exported `NCODE_X` over `SWARM_X`, and the provider-file loader does the same
  for the file's names while shell exports keep winning over the file.

  Run as subprocesses against a stub release, as `launcher_test.exs` does. The
  real `~/.secrets` is never read: every loader run names its own file and a
  temporary `HOME`.
  """
  use ExUnit.Case, async: true

  @bin Path.expand("../../../../../rel/overlays/bin", __DIR__)
  @loader Path.expand("../../../../../scripts/dev/load_provider_env.sh", __DIR__)

  # {NCODE name, the SWARM name the release reads}
  @aliases [
    {"NCODE_MODEL", "SWARM_MODEL"},
    {"NCODE_BASE_URL", "SWARM_BASE_URL"},
    {"NCODE_API_KEY", "SWARM_API_KEY"},
    {"NCODE_PROVIDER", "SWARM_PROVIDER"},
    {"NCODE_EFFORT", "SWARM_EFFORT"},
    {"NCODE_CONVERSATION", "SWARM_CONVERSATION"},
    {"NCODE_KEYMAP", "SWARM_KEYMAP"},
    {"NCODE_ASCII", "SWARM_ASCII"},
    {"NCODE_COMPANION", "SWARM_COMPANION"},
    {"NCODE_THEME", "SWARM_THEME"},
    {"NCODE_MOUSE", "SWARM_MOUSE"},
    {"NCODE_APPROVAL", "SWARM_APPROVAL"},
    {"NCODE_ENV_FILE", "SWARM_ENV_FILE"},
    {"NCODE_CONFIG_DIR", "SWARM_CODE_CONFIG_DIR"},
    {"NCODE_SHELL", "SWARM_CODE_SHELL"}
  ]

  @extra ~w(LLMOTIONS_API_KEY GITHUB_TOKEN SWARM_MODEL_OVERRIDE NCODE_MODEL_OVERRIDE
            OPENAI_API_KEY ANTHROPIC_API_KEY SWARM_RELEASE_TUI)

  @printed Enum.flat_map(@aliases, fn {ncode, swarm} -> [ncode, swarm] end) ++ @extra

  @stub """
  #!/usr/bin/env bash
  for name in #{Enum.join(@printed, " ")}; do
    if [[ -n ${!name+x} ]]; then
      printf '%s=%s\\n' "$name" "${!name}"
    else
      printf '%s=<unset>\\n' "$name"
    fi
  done >"$STUB_LOG"
  exit 0
  """

  setup do
    base = Path.join(System.tmp_dir!(), "ncode-alias-#{System.unique_integer([:positive])}")
    bin = Path.join(base, "release/bin")
    project = Path.join(base, "project")
    home = Path.join(base, "home")
    Enum.each([bin, project, home, Path.join(base, "release/releases")], &File.mkdir_p!/1)

    for name <- ~w(ncode swarmcode swarm-code) do
      File.cp!(Path.join(@bin, name), Path.join(bin, name))
      File.chmod!(Path.join(bin, name), 0o755)
    end

    File.write!(Path.join(bin, "swarm_code_cli"), @stub)
    File.chmod!(Path.join(bin, "swarm_code_cli"), 0o755)
    File.write!(Path.join(bin, "load_provider_env.sh"), ":\n")
    File.write!(Path.join(base, "release/releases/start_erl.data"), "16.0 0.1.0\n")
    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, bin: bin, project: project, home: home, log: Path.join(base, "stub.log")}
  end

  # Every name the stub prints starts unset, whatever the shell running the
  # suite exports; the test's own names come after.
  defp clean_env(context, env) do
    Enum.map(@printed, &{&1, nil}) ++
      [
        {"STUB_LOG", context.log},
        {"HOME", context.home},
        {"SWARM_CONVERSATION", nil},
        {"TERM", "xterm-256color"}
      ] ++ env
  end

  defp run(context, command, args, env \\ []) do
    {output, code} =
      System.cmd(Path.join(context.bin, command), args,
        env: clean_env(context, env),
        cd: context.project,
        stderr_to_stdout: true
      )

    {code, output}
  end

  defp stub(context) do
    context.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {key, value}
    end)
  end

  defp use_real_loader(context) do
    File.cp!(@loader, Path.join(context.bin, "load_provider_env.sh"))
  end

  describe "the old names" do
    test "bin/swarmcode --version prints ncode's version and nothing on stderr without a terminal",
         context do
      # stderr is merged into the output: an exact match proves the alias said nothing.
      assert {0, "ncode 0.1.0\n"} = run(context, "swarmcode", ["--version"])
      refute File.exists?(context.log)
    end

    test "bin/swarmcode passes every argument and the exit code through", context do
      assert {2, "ncode: unknown option '--bogus'. Run 'ncode --help'.\n"} =
               run(context, "swarmcode", ["--bogus"])

      assert {0, ""} = run(context, "swarmcode", ["-p", "hi"])
      assert stub(context)["SWARM_CONVERSATION"] == "new"
    end

    test "bin/swarm-code tui --version still works", context do
      assert {0, "ncode 0.1.0\n"} = run(context, "swarm-code", ["tui", "--version"])
      assert {0, "ncode 0.1.0\n"} = run(context, "swarm-code", ["--version"])
    end
  end

  describe "NCODE_* first, SWARM_* as the fallback" do
    test "NCODE_THEME wins over SWARM_THEME, and SWARM_THEME alone still works", context do
      run(context, "ncode", ["-p", "hi"], [{"NCODE_THEME", "light"}, {"SWARM_THEME", "dark"}])
      assert stub(context)["SWARM_THEME"] == "light"

      run(context, "ncode", ["-p", "hi"], [{"SWARM_THEME", "dark"}])
      assert stub(context)["SWARM_THEME"] == "dark"

      run(context, "ncode", ["-p", "hi"], [{"NCODE_THEME", "light"}])
      assert stub(context)["SWARM_THEME"] == "light"
    end

    test "every exported NCODE_ name replaces its SWARM_ name; alone, the SWARM_ name stays",
         context do
      both =
        Enum.flat_map(@aliases, fn {ncode, swarm} ->
          [{ncode, "n-" <> ncode}, {swarm, "s-" <> swarm}]
        end)

      assert {0, ""} = run(context, "ncode", ["-p", "hi"], both)
      log = stub(context)
      for {ncode, swarm} <- @aliases, do: assert(log[swarm] == "n-" <> ncode, swarm)

      only_swarm = Enum.map(@aliases, fn {_ncode, swarm} -> {swarm, "s-" <> swarm} end)
      assert {0, ""} = run(context, "ncode", ["-p", "hi"], only_swarm)
      log = stub(context)
      for {_ncode, swarm} <- @aliases, do: assert(log[swarm] == "s-" <> swarm, swarm)
    end

    test "an empty NCODE_API_KEY is still a key (unauthenticated local APIs)", context do
      # System.cmd drops an empty value from the environment, so a shell sets it.
      {_, 0} =
        System.cmd(
          "bash",
          ["-c", ~s(NCODE_API_KEY= exec "$0" "$@"), Path.join(context.bin, "ncode"), "-p", "hi"],
          env: clean_env(context, [{"SWARM_API_KEY", "old"}]),
          cd: context.project,
          stderr_to_stdout: true
        )

      assert stub(context)["SWARM_API_KEY"] == ""
    end
  end

  describe "the provider file loader" do
    setup context do
      use_real_loader(context)
      %{env_file: Path.join(context.base, "secrets.env")}
    end

    test "passes LLMOTIONS_API_KEY and NCODE_MODEL; never other tokens or a model override",
         context do
      File.write!(context.env_file, """
      export NCODE_MODEL=file-ncode-model
      export SWARM_MODEL=file-swarm-model
      export LLMOTIONS_API_KEY=llm-test-key
      export GITHUB_TOKEN=gh-test-token
      export NCODE_MODEL_OVERRIDE=never
      export SWARM_MODEL_OVERRIDE=never
      """)

      assert {0, ""} =
               run(context, "ncode", ["-p", "hi"], [{"NCODE_ENV_FILE", context.env_file}])

      log = stub(context)
      assert log["LLMOTIONS_API_KEY"] == "llm-test-key"
      assert log["NCODE_MODEL"] == "file-ncode-model"
      # Inside the file the NCODE_ name wins too.
      assert log["SWARM_MODEL"] == "file-ncode-model"
      assert log["GITHUB_TOKEN"] == "<unset>"
      assert log["NCODE_MODEL_OVERRIDE"] == "<unset>"
      assert log["SWARM_MODEL_OVERRIDE"] == "<unset>"
    end

    test "every NCODE_ name in the file reaches its SWARM_ name; shell exports still win",
         context do
      from_file = Enum.reject(@aliases, fn {ncode, _} -> ncode == "NCODE_ENV_FILE" end)

      File.write!(
        context.env_file,
        Enum.map_join(from_file, fn {ncode, swarm} ->
          "export #{swarm}=file-#{swarm}\nexport #{ncode}=file-#{ncode}\n"
        end)
      )

      assert {0, ""} =
               run(context, "ncode", ["-p", "hi"], [{"SWARM_ENV_FILE", context.env_file}])

      log = stub(context)
      for {ncode, swarm} <- from_file, do: assert(log[swarm] == "file-" <> ncode, swarm)

      File.write!(context.env_file, "export NCODE_MODEL=file-ncode-model\n")

      run(context, "ncode", ["-p", "hi"], [
        {"SWARM_ENV_FILE", context.env_file},
        {"SWARM_MODEL", "shell-model"}
      ])

      assert stub(context)["SWARM_MODEL"] == "shell-model"
    end

    # Review A5: the dev launchers (scripts/dev/run_*.sh) source the loader
    # directly, without bin/ncode's copy, so the loader maps exported names too.
    test "sourced on its own, the loader copies exported NCODE_ names over SWARM_ names",
         context do
      File.write!(context.env_file, """
      export SWARM_API_KEY=file-key
      export SWARM_MODEL=file-model
      """)

      print =
        ~s(for name in #{Enum.join(@printed, " ")}; do ) <>
          ~s(if [[ -n ${!name+x} ]]; then printf '%s=%s\\n' "$name" "${!name}"; fi; done)

      source = fn env ->
        {output, 0} =
          System.cmd("bash", ["--noprofile", "--norc", "-c", ~s(. "$1"; ) <> print, "t", @loader],
            env: clean_env(context, [{"SWARM_ENV_FILE", context.env_file} | env]),
            stderr_to_stdout: true
          )

        output
        |> String.split("\n", trim: true)
        |> Map.new(&List.to_tuple(String.split(&1, "=", parts: 2)))
      end

      exported = Enum.map(@aliases, fn {ncode, _} -> {ncode, "shell-" <> ncode} end)

      exported =
        List.keystore(exported, "NCODE_ENV_FILE", 0, {"NCODE_ENV_FILE", context.env_file})

      vars = source.(exported)

      for {ncode, swarm} <- @aliases, do: assert(vars[swarm] == vars[ncode], swarm)
      # The exported NCODE_API_KEY counts as a key, so the file is not read.
      assert vars["SWARM_API_KEY"] == "shell-NCODE_API_KEY"
      assert vars["SWARM_MODEL"] == "shell-NCODE_MODEL"

      # Without an exported key the file is read, and the exported name still wins.
      vars = source.([{"NCODE_MODEL", "shell-model"}])
      assert vars["SWARM_MODEL"] == "shell-model"
      assert vars["SWARM_API_KEY"] == "file-key"
    end

    test "a missing NCODE_ENV_FILE is refused by name", context do
      missing = Path.join(context.base, "missing.env")
      assert {code, output} = run(context, "ncode", ["-p", "hi"], [{"NCODE_ENV_FILE", missing}])
      assert code != 0

      assert output =~
               "NCODE_ENV_FILE (or SWARM_ENV_FILE) must point to an existing environment file."

      refute File.exists?(context.log)
    end
  end
end
