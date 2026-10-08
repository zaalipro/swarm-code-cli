defmodule SwarmCodeCLI.Entry.BuildReleaseScriptTest do
  # cli020 fix round (integrator): the daemon's C and Objective-C helpers in
  # `priv/native` are shared by every MIX_ENV and rebuilt only when their source
  # changes, so the release copied helpers a dev or test build had compiled for
  # the host's macOS (minos 26.0 on a macOS 26 machine), although the script
  # exports MACOSX_DEPLOYMENT_TARGET=15.0 for the release. The script must
  # rebuild them under that target before `mix release` copies them.
  use ExUnit.Case, async: true

  @script Path.expand("../../../../../scripts/dev/build_release.sh", __DIR__)

  defp lines, do: @script |> File.read!() |> String.split("\n")

  defp index_of(pattern) do
    Enum.find_index(lines(), fn line ->
      not String.starts_with?(String.trim_leading(line), "#") and line =~ pattern
    end)
  end

  test "the native helpers are rebuilt for the deployment target before the release" do
    target = index_of(~r/^export MACOSX_DEPLOYMENT_TARGET=/)
    env = index_of(~r/^export MIX_ENV=/)
    rebuild = index_of(~r/mix compile\.schema_snapshot --force/)
    release = index_of(~r/mix release swarm_code_cli/)

    assert is_integer(target) and is_integer(env) and is_integer(release)
    assert is_integer(rebuild), "build_release.sh does not rebuild the native helpers"
    assert target < rebuild and env < rebuild and rebuild < release
  end
end
