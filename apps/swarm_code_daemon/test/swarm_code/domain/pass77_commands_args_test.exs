defmodule SwarmCode.Domain.Pass77CommandsArgsTest do
  @moduledoc "pass 77 D3-3 (D-FEAT-14 / C-FEAT-8): positional arguments and the bundled /init."
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.{Commands, Fixtures}

  defp command(body), do: %{body: body}

  describe "split_args/1" do
    test "splits on whitespace and honours quotes" do
      assert Commands.split_args("fix-issue 123 high") == ["fix-issue", "123", "high"]

      assert Commands.split_args(~s(say "hello there" 'and more' x)) == [
               "say",
               "hello there",
               "and more",
               "x"
             ]

      assert Commands.split_args(~s("a \\"quoted\\" word" b)) == [~s(a "quoted" word), "b"]
      assert Commands.split_args("   ") == []
      assert Commands.split_args("") == []
    end

    test "an unterminated quote keeps the rest as one argument" do
      assert Commands.split_args(~s(a "b c)) == ["a", "b c"]
    end
  end

  describe "expand/2" do
    test "$1 and $2 take the positional arguments" do
      body = "Fix issue $1 with priority $2."
      assert Commands.expand(command(body), "123 high") == "Fix issue 123 with priority high."
    end

    test "a missing positional argument becomes empty" do
      assert Commands.expand(command("a $1 b $2 c"), "only") == "a only b  c"
    end

    test "a quoted argument is one positional argument" do
      assert Commands.expand(command("title: $1 / $2"), ~s("two words" next)) ==
               "title: two words / next"
    end

    test "$10 stays literal (only $1-$9 are positional)" do
      assert Commands.expand(command("$10 and $1"), "x y") == "$10 and x"
    end

    test "$ARGUMENTS is the whole text, and what the user typed is never re-expanded" do
      assert Commands.expand(command("all: $ARGUMENTS | first: $1"), "keep $1 literal") ==
               "all: keep $1 literal | first: keep"

      assert Commands.expand(command("$ARGUMENTS"), "price is $2 and $ARGUMENTS") ==
               "price is $2 and $ARGUMENTS"
    end

    test "the old behaviour is unchanged: $ARGUMENTS alone, trimmed" do
      assert Commands.expand(command("Do this: $ARGUMENTS\n"), "  the thing  ") ==
               "Do this: the thing"
    end
  end

  describe "the built-in tier" do
    test "/init is listed with the :builtin scope" do
      init = Enum.find(Commands.list(nil), &(&1.name == "init"))

      assert init
      assert init.scope == :builtin
      assert init.description =~ "AGENTS.md"
      assert init.body =~ "AGENTS.md"
      assert init.body =~ "CLAUDE.md"
      assert Commands.get(nil, "init").scope == :builtin
    end

    test "a project init.md overrides the built-in one" do
      dir = Fixtures.tmp_dir()
      commands = Path.join([dir, ".swarm_code", "commands"])
      File.mkdir_p!(commands)
      File.write!(Path.join(commands, "init.md"), "---\ndescription: mine\n---\nmy init\n")

      project = %{root_path: dir}
      init = Commands.get(project, "init")

      assert init.scope == :project
      assert init.description == "mine"
      assert init.body == "my init"
      assert Enum.count(Commands.list(project), &(&1.name == "init")) == 1
    end

    test "the starter template documents the positional arguments" do
      dir = Fixtures.tmp_dir()
      assert {:ok, path} = Commands.create(%{root_path: dir}, :project, "starter")
      text = File.read!(path)
      assert text =~ "$ARGUMENTS"
      assert text =~ "$1"
    end
  end
end
