defmodule SwarmCode.Domain.Tools.Pass76CommandSafetyTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Engine.Policy
  alias SwarmCode.Domain.Tools.CommandSafety

  test "quoted and escaped unsafe options fail closed in auto" do
    commands = [
      ~s(rg "--pre=sh" x payload.sh),
      ~s(rg '--pre=sh' x payload.sh),
      ~s(rg --"pre=sh" x payload.sh),
      ~S(rg \--pre=sh x payload.sh),
      ~s(sort "-o" output.txt input.txt),
      ~s(sort '--output=output.txt' input.txt),
      ~s(sort -o"output.txt" input.txt),
      ~s(tree "-o" output.txt),
      ~s(yq '-i' '.foo' file.yml),
      ~s(yq --"inplace" '.foo' file.yml),
      ~S(yq \-i '.foo' file.yml)
    ]

    for command <- commands do
      class = CommandSafety.classify(command)
      assert class in [:normal, :dangerous], command
      assert Policy.decide("auto", :execute, class) == :ask
    end
  end

  test "safe quoted operands and git status remain allowed in auto" do
    for command <- [
          ~s(cat "lib/a b.ex"),
          ~s(cat 'lib/a b.ex'),
          ~S(cat lib/a\ b.ex),
          ~s(cat li'b/'"a b.ex"),
          ~s(cat "lib/{a,b}.ex"),
          ~s(cat 'lib/{a,b}.ex'),
          ~S(cat lib/\{a,b\}.ex),
          ~s(cat "lib/{1..2}.ex"),
          ~s(cat lib/"{a,b}".ex),
          ~s(cat lib/{"a,b"}.ex),
          ~S(cat lib/{a\,b}.ex),
          ~S(cat lib/{1\..2}.ex),
          ~S(cat lib/{a,b.ex),
          "cat lib/a}.ex",
          "git status",
          "cat lib/../mix.exs",
          "command cat mix.exs",
          "timeout -s KILL 5 cat mix.exs",
          ~s(sh -c 'cat mix.exs'),
          "git stash show -p stash@{0}",
          "cat mix.exs | grep version"
        ] do
      class = CommandSafety.classify(command)
      assert class == :safe, command
      assert Policy.decide("auto", :execute, class) == :allow
      assert Policy.decide("read_only", :execute, class) == :ask
    end
  end

  test "unknown syntax and input redirects fail closed" do
    for command <- [
          ~s(cat </tmp/outside),
          ~s(cat < /tmp/outside),
          ~s(cat "lib/a b.ex),
          ~s(cat lib/a\\),
          ~s(cat lib/*.ex),
          ~S|cat $(printf lib/a.ex)|,
          ~s(cat "${HOME}/a"),
          ~s(cat '' /etc/passwd),
          ~s(rg "" /etc/passwd),
          ~S(cat "../outside"),
          ~S(cat lib/?a),
          ~S(cat lib/[ab]),
          ~S(echo ~),
          ~S(echo {a,b}),
          ~S(cat < mix.exs),
          ~S(cat<mix.exs),
          ~S(cat lib/a" b),
          "cat lib/a\\",
          ~S(echo $HOME),
          ~S|echo <(cat mix.exs)|,
          ~S|echo `cat mix.exs`|,
          ~S(cat lib/{a,b}.ex),
          ~S(cat lib/{1..2}.ex),
          ~S(cat lib/{a,"b"}.ex),
          ~S(cat lib/"prefix"{a,b}.ex),
          ~S(cat lib/{1..2}".ex"),
          ~S(cat lib/{a,{b,c}}.ex),
          ~s(cat "../{a,b}.ex"),
          ~s(cat "/tmp/{1..2}.ex"),
          ~s(sh -c 'cat mix.exs),
          ~s(env -S 'cat mix.exs)
        ] do
      refute CommandSafety.classify(command) == :safe, command
      assert Policy.decide("auto", :execute, CommandSafety.classify(command)) == :ask
    end
  end

  test "dangerous detection still takes precedence over uncertain syntax" do
    assert CommandSafety.classify(~s(rm -rf "$HOME)) == :dangerous
    assert CommandSafety.classify("sudo rm -rf /") == :dangerous
  end

  test "every unsafe option spelling has the same classifier and policy result" do
    for {program, option, operands} <- [
          {"rg", "--pre=sh", "x payload.sh"},
          {"rg", "--search-zip", "x payload.sh"},
          {"rg", "-nz", "x payload.sh"},
          {"sort", "--output=output.txt", "input.txt"},
          {"sort", "--compress-program=sh", "input.txt"},
          {"sort", "-ro", "output.txt input.txt"},
          {"tree", "-ao", "output.txt"},
          {"tree", "-aR", "."},
          {"yq", "--inplace", "'.foo' file.yml"},
          {"yq", "--split-exp=.foo", "'.foo' file.yml"},
          {"yq", "-Pi", "'.foo' file.yml"},
          {"yq", "-Ps", "'.foo' file.yml"}
        ],
        spelling <- [
          option,
          "'" <> option <> "'",
          "\"" <> option <> "\"",
          "\\" <> option,
          "-" <> "'" <> String.slice(option, 1..-1//1) <> "'"
        ] do
      command = Enum.join([program, spelling, operands], " ")

      assert {CommandSafety.classify(command),
              Policy.decide("auto", :execute, CommandSafety.classify(command))} ==
               {:normal, :ask},
             command
    end
  end

  test "wrappers, strictest segments and prefix families retain their authority" do
    assert CommandSafety.classify("time -o out cat mix.exs") == :normal
    assert CommandSafety.classify("env FOO=1 cat mix.exs") == :normal
    assert CommandSafety.classify("cat mix.exs && sort '-o' out mix.exs") == :normal
    assert CommandSafety.classify("cat mix.exs && sudo whoami") == :dangerous
    assert CommandSafety.prefix("git status") == "git status"
    assert CommandSafety.prefix("command git status") == "git status"
    assert CommandSafety.prefix("rm -r build") == "rm -r"
    assert CommandSafety.prefix("cat mix.exs | grep version") == ""
  end
end
