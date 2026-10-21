defmodule SwarmCode.Domain.Tools.Pass77CommandSafetyTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Engine.Policy
  alias SwarmCode.Domain.Tools.CommandSafety

  # pass 77 X-6 (C-BUG-2, C-BUG-3)

  test "a project-local wrapper or shell is that program, never the command behind it" do
    for command <- [
          "./env pwd",
          "./bash -c pwd",
          "/tmp/x/nohup ls",
          "./timeout 5 ls",
          "bin/xargs ls",
          "./sh -c 'git status'"
        ] do
      class = CommandSafety.classify(command)
      refute class == :safe, command
      assert Policy.decide("auto", :execute, class) == :ask, command
    end
  end

  test "a shell option that can run code before the script is never safe" do
    for command <- [
          "bash --rcfile payload -ic pwd",
          "bash --init-file payload -c pwd",
          "bash -ic pwd",
          "fish -C 'rm -rf ~' -c pwd",
          "fish '--init-command=rm -rf ~' -c pwd",
          "zsh --login -c pwd",
          "env BASH_ENV=./x.sh bash -c ls",
          "BASH_ENV=./x.sh bash -c ls"
        ] do
      class = CommandSafety.classify(command)
      refute class == :safe, command
      assert Policy.decide("auto", :execute, class) == :ask, command
    end
  end

  test "plain system shells and wrappers keep the class of their script" do
    for command <- [
          "bash -c ls",
          "sh -c 'cat mix.exs'",
          "bash -lc 'git status'",
          "bash -o pipefail -c ls",
          "bash --noprofile --norc -c ls",
          "/bin/bash -c ls",
          "/usr/bin/env ls",
          "env ls"
        ] do
      assert CommandSafety.classify(command) == :safe, command
    end
  end

  test "a dangerous body or an escalation stays dangerous" do
    assert CommandSafety.classify("bash --rcfile x -c 'rm -rf ~'") == :dangerous
    assert CommandSafety.classify("./sudo ls") == :dangerous
  end
end
