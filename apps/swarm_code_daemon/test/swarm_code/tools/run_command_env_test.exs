defmodule SwarmCode.Tools.RunCommandEnvTest do
  # cli020 A5: the live runtime's `run_command` copy (frozen at fb1b4ff) gets
  # the desktop's spec 66 T6 secret scrub and the CLI's pass71 F6 user umask,
  # which the synced domain copy already has: an unsaved session's model must
  # not read the launcher's provider keys with `env`, and a file it creates
  # gets the user's umask, not the VM's 077.
  use ExUnit.Case, async: false

  alias SwarmCode.Tools.RunCommand

  setup do
    root = Path.join(System.tmp_dir!(), "live-run-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    names = ~w(CLI020_FAKE_API_KEY CLI020_FAKE_SECRET GH_TOKEN CLI020_PLAIN SWARM_USER_UMASK)
    before = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- before,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

      File.rm_rf!(root)
    end)

    %{ctx: %{project_root: root}, root: root}
  end

  test "secret-looking variables never reach the command; GH_TOKEN and plain ones do", c do
    System.put_env("CLI020_FAKE_API_KEY", "sk-test-fixture")
    System.put_env("CLI020_FAKE_SECRET", "hidden")
    System.put_env("GH_TOKEN", "gh-test-fixture")
    System.put_env("CLI020_PLAIN", "visible")

    # Only names are compared and only a fixed message is printed on failure:
    # the command's output is the whole environment, real keys included.
    assert {:ok, out} = RunCommand.run(%{"command" => "env"}, c.ctx, fn _, _ -> :ok end)
    names = names(out)
    refute "CLI020_FAKE_API_KEY" in names, "an API key reached the command"
    refute "CLI020_FAKE_SECRET" in names, "a secret reached the command"
    assert "GH_TOKEN" in names, "GH_TOKEN was scrubbed"
    assert "CLI020_PLAIN" in names, "a plain variable was scrubbed"

    secret = ~r/(API_?KEY|_KEY$|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|_PAT$)/i

    leaked =
      Enum.filter(names, &(Regex.match?(secret, &1) and &1 not in ["GH_TOKEN", "GITHUB_TOKEN"]))

    assert leaked == [], "#{length(leaked)} secret-looking variable(s) reached the command"
  end

  defp names(out) do
    out
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/\A([A-Za-z_][A-Za-z0-9_]*)=/, line) do
        [_, name] -> [name]
        _ -> []
      end
    end)
  end

  test "the command runs under the user's umask from SWARM_USER_UMASK", c do
    System.put_env("SWARM_USER_UMASK", "027")
    assert {:ok, out} = RunCommand.run(%{"command" => "umask"}, c.ctx, fn _, _ -> :ok end)
    assert String.contains?(out, "0027"), "the user's umask was not applied"

    System.put_env("SWARM_USER_UMASK", "not a umask")
    assert {:ok, _out} = RunCommand.run(%{"command" => "true"}, c.ctx, fn _, _ -> :ok end)
  end
end
