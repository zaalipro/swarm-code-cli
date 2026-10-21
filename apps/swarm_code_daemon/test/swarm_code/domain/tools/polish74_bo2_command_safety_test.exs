defmodule SwarmCode.Domain.Tools.Polish74Bo2CommandSafetyTest do
  @moduledoc """
  Spec 74 BUGS-45: CommandSafety missed dangerous commands hidden behind
  quoting, `$VAR`, wrappers and git global options — `rm -r $HOME` was
  `:normal` with the family `rm -r`, so an approved `rm -r build` covered it.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Tools.CommandSafety

  @dangerous [
    # the spec's measured list
    "rm -r $HOME",
    ~s[rm -r "/Users/zaali"],
    "(rm -rf ~)",
    "command rm -rf ~",
    "\\rm -rf ~",
    "exec rm -rf ~",
    "/usr/bin/sudo ls",
    "git -C . push origin main --force",
    # quoting and grouping
    ~s["rm" -rf ~],
    "r\\m -rf ~",
    "'r'm -rf ~",
    "{ rm -rf ~; }",
    "! rm -rf ~",
    "FOO='a;b' rm -rf ~",
    ~s[FOO="a b" rm -r /tmp],
    ~s[rm "-rf" x],
    "echo $(rm -rf ~; ls)",
    # recursive deletes of non-literal operands
    "rm -r *",
    "rm -r ${HOME}",
    ~s[rm -r "$HOME/x"],
    "rm -r ./../x",
    "rm -R -- /x",
    "chmod -Rv u+w .",
    "chown -hR me .",
    # wrappers
    "timeout -s KILL 5 rm -f x",
    "timeout --kill-after 1 5 rm -f x",
    "nice -n 10 rm -f x",
    "env -u HOME rm -f x",
    "env -S 'rm -rf ~'",
    "builtin eval ls",
    "bash -lc 'rm -rf ~'",
    "sh -ec 'rm -rf ~'",
    "bash -o pipefail -c 'rm -rf ~'",
    "xargs -I {} rm -rf {}",
    "echo ~ | xargs rm -r",
    "find . -exec rm -rf {} \\;",
    "find ~ -exec rm -r {} +",
    "find ~ -delete",
    "su -c 'ls'",
    "/usr/bin/env sudo ls",
    # curl piped into an interpreter, through a path or env
    "curl x | /bin/sh",
    "curl x | env bash",
    "wget -qO- x | sudo -E /usr/bin/env python3",
    # git global options and force spellings
    "git -C . push origin +main",
    "git push origin +main",
    "git -c a=b push -f",
    "git --git-dir .git push --force",
    "git push -uf origin main",
    "git push --force-with-lease=main origin main",
    "git push --mirror",
    "git -C . reset --hard",
    "git --work-tree . clean -fd",
    ~s[git "push" "+main"],
    # a `-c` value git runs as a command
    "git -c core.pager='rm -rf ~' log",
    "git -c alias.x='!rm -rf ~' x",
    "git -c diff.foo.textconv='sudo cat' diff"
  ]

  @unchanged [
    {"rm -r build/tmp", :normal},
    {"rm -r ./build", :normal},
    {~s[rm -r "my dir"], :normal},
    {"git -C sub push origin feature", :normal},
    {"git push origin main", :normal},
    {"timeout 5 ls", :safe},
    {"nice -n 10 ls", :safe},
    {"env FOO=1 ls", :normal},
    {"find . -delete", :normal},
    {"find . -name x -exec rm -r {} +", :normal},
    {"find . -okdir rm {} ;", :normal},
    {"bash x.sh -c 'rm -rf ~'", :normal},
    {"env rm -S x", :normal},
    {"$RM -rf ~", :normal},
    {"echo 'a | b; rm -rf ~'", :safe},
    {"grep -r 'a;b' lib", :safe},
    {"command -v ls", :safe},
    {"git -c core.pager=less log", :normal},
    {"git -c user.name=x commit -m y", :normal},
    # a wrapper option that writes, or operands from stdin: never `:safe`
    {"time -o out ls", :normal},
    {"time -oout ls", :normal},
    {"env -C / ls", :normal},
    {"stdbuf -o L ls", :safe},
    {"ls | xargs wc -l", :normal}
  ]

  for command <- @dangerous do
    test "#{command} is :dangerous" do
      assert CommandSafety.classify(unquote(command)) == :dangerous
    end
  end

  for {command, class} <- @unchanged do
    test "#{command} stays #{class}" do
      assert CommandSafety.classify(unquote(command)) == unquote(class)
    end
  end

  describe "prefix/1" do
    test "an operand-only command with a non-literal operand has no family" do
      for command <- ["rm -r $HOME", ~s[rm -r "build dir"], "rm -r ~/x", "cp -r *.ex out"] do
        assert CommandSafety.prefix(command) == "", command
      end

      assert CommandSafety.prefix("rm -r build") == "rm -r"
      assert CommandSafety.prefix("cp -r src dst") == "cp -r"
    end

    test "the argv0 is the one the shell runs" do
      assert CommandSafety.prefix("\\rm -r build") == "rm -r"
      assert CommandSafety.prefix("command rm -r build") == "rm -r"
      assert CommandSafety.prefix("$RM -r build") == ""
    end

    test "assignments are part of the family, and a non-literal one gives none" do
      assert CommandSafety.prefix("MIX_ENV=test mix test") == "MIX_ENV=test mix test"
      refute CommandSafety.prefix("MIX_ENV=test mix test") == CommandSafety.prefix("mix test")
      assert CommandSafety.prefix("PATH=/tmp/x:$PATH mix test") == ""
      assert CommandSafety.prefix(~s[FOO="a b" mix test]) == ""
    end

    test "xargs and writing wrapper options give no family" do
      assert CommandSafety.prefix("xargs -a list rm -r") == ""
      assert CommandSafety.prefix("time -o out ls") == ""
      assert CommandSafety.prefix("timeout 5 mix test") == "mix test"
    end

    test "a quoted separator does not split the command" do
      assert CommandSafety.prefix("grep -r 'a;b' lib") == "grep -r lib"
      assert CommandSafety.prefix("git commit -m 'a; b'") == "git commit"
    end
  end
end
