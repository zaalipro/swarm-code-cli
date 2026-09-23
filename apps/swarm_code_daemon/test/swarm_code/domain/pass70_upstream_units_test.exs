defmodule SwarmCode.Domain.Pass70UpstreamUnitsTest do
  @moduledoc """
  Pure unit tests of synced domain modules, ported by hand from desktop test
  files that cannot be synced whole (each also holds tests that need the
  desktop's `DataCase`, `LLM.Fake` or its fixtures). Sources at desktop
  6dd8d82, kept as close to the originals as the CLI allows:

    * FuzzyMatch — `test/swarm_code/polish69_b_tools_test.exs` "spec 73 T94"
    * LSP.Language — `test/swarm_code/polish67_lsp_test.exs` "Language", "file URIs"
    * Context hysteresis — `test/swarm_code/engine/polish68_budgets_test.exs` "spec 72 B4"
    * edit_file passes — `test/swarm_code/tools/polish60_edit_test.exs` "T9"
    * Ripgrep and its fallback — `test/swarm_code/tools/polish67_tools_test.exs` "C1", "C3"

  The pure upstream test files themselves are synced by
  `mix swarm_code.provenance.sync` (the `test/swarm_code/` mapping).
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.{Fixtures, FuzzyMatch, Tools}
  alias SwarmCode.Domain.Engine.Context
  alias SwarmCode.Domain.LSP.Language
  alias SwarmCode.Domain.Tools.Ripgrep

  describe "FuzzyMatch works in bytes (spec 73 T94)" do
    test "a non-ASCII prefix does not move the bonuses or lose the match" do
      assert {:match, ascii} = FuzzyMatch.score("docs/resume/notes.md", "n.md")
      assert {:match, accented} = FuzzyMatch.score("docs/résumé/notes.md", "n.md")
      assert accented == ascii

      assert {:match, _} = FuzzyMatch.score("docs/résumé.md", "rés")
      assert {:match, _} = FuzzyMatch.score("🚀/launch/plan.ex", "lp")
      assert :no_match = FuzzyMatch.score("docs/résumé.md", "zz")
    end

    test "the segment bonus lands on the character after the separator" do
      {:match, after_slash} = FuzzyMatch.score("é/x", "x")
      {:match, plain} = FuzzyMatch.score("éax", "x")
      assert after_slash == plain + 3
    end

    test "filter keeps every candidate the query fits, accented or not" do
      ranked = FuzzyMatch.filter(["réunion/cmd.ex", "run_command.ex", "nothing.ex"], "runc", 3)
      assert Enum.sort(ranked) == ["run_command.ex", "réunion/cmd.ex"]
    end
  end

  describe "LSP.Language (spec 70 B1, B4)" do
    test "detect/1 maps extensions to languages" do
      assert Language.detect("lib/my_app/foo.ex") == "elixir"
      assert Language.detect("README.txt") == nil
      assert Language.detect("app/page.tsx") == "typescript"
    end

    test "server_command/2 splits the default and honours overrides and off" do
      assert Language.server_command("typescript") == ["typescript-language-server", "--stdio"]

      assert Language.server_command("python", %{"python" => "my-ls --stdio"}) == [
               "my-ls",
               "--stdio"
             ]

      assert Language.server_command("python", %{"python" => "off"}) == nil
      assert Language.server_command("brainfuck") == nil
    end

    test "file URIs are percent-encoded per segment and decoded back" do
      assert Language.file_uri("/tmp/My Project/a#b%c.ex") ==
               "file:///tmp/My%20Project/a%23b%25c.ex"

      assert Language.uri_to_path("file:///tmp/My%20Project/a%23b%25c.ex") ==
               "/tmp/My Project/a#b%c.ex"

      assert Language.uri_to_path("untitled:x") == "untitled:x"
    end
  end

  describe "stable-prefix context trimming with hysteresis (spec 72 B4)" do
    test "no trim below budget" do
      messages = [%{role: "user", content: "hello"}]
      assert Context.trim(messages, 100_000) === messages
    end

    test "trim to low water when over budget" do
      messages = [%{role: "user", content: "start"} | Enum.flat_map(0..19, &exchange(&1, 400))]
      budget = 500
      assert Context.estimate_tokens(Context.trim(messages, budget)) <= trunc(budget * 0.7)
    end

    test "untouched messages stay byte-identical across a later trim" do
      messages = [%{role: "user", content: "start"} | Enum.flat_map(0..19, &exchange(&1, 400))]
      budget = 500
      trimmed = Context.trim(messages, budget)
      count = length(trimmed)

      grown = trimmed ++ [Context.count(%{role: "user", content: "follow up"})]
      assert Context.estimate_tokens(grown) <= budget

      again = Context.trim(grown, budget)
      assert length(again) == count + 1
      assert Enum.take(again, count) === trimmed
    end

    test "what survives a trim is the ordered suffix, newest untouched" do
      messages = [%{role: "user", content: "start"} | Enum.flat_map(0..19, &exchange(&1, 400))]
      budget = 500
      first = Context.trim(messages, budget)
      second = Context.trim(first ++ Enum.flat_map(20..22, &exchange(&1, 10)), budget)
      assert Enum.take(second, length(first)) === first

      messages3 = second ++ Enum.flat_map(23..27, &exchange(&1, 400))
      third = Context.trim(messages3, budget)
      assert third != [] and length(third) < length(messages3)
      kept = Enum.drop(messages3, length(messages3) - length(third))

      for {before, after_} <- Enum.zip(kept, third) do
        assert before === after_ or
                 (before.role == "tool" and after_.role == "tool" and
                    before.tool_call_id == after_.tool_call_id and
                    (String.starts_with?(after_.content, "[tool output omitted") or
                       after_.content =~ "[tool output cut to fit the context"))
      end

      assert List.last(third).tool_call_id == "t27"
    end
  end

  describe "edit_file's four matching passes (spec 66 T9)" do
    setup do
      dir = Fixtures.tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir, ctx: %{project_root: dir}}
    end

    test "pass 1 is byte-exact and says nothing about a pass", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.ex"), "defmodule A do\n  def x, do: 1\nend\n")

      assert {:ok, "edited a.ex: 1 replacement(s)"} =
               edit(ctx, %{
                 "path" => "a.ex",
                 "old_string" => "def x, do: 1",
                 "new_string" => "def x, do: 2"
               })

      assert File.read!(Path.join(dir, "a.ex")) == "defmodule A do\n  def x, do: 2\nend\n"
    end

    test "pass 2 ignores trailing whitespace", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.ex"), "one\ntwo   \nthree\n")

      assert {:ok, "edited a.ex: 1 replacement(s) (matched ignoring trailing whitespace)"} =
               edit(ctx, %{
                 "path" => "a.ex",
                 "old_string" => "two\nthree",
                 "new_string" => "TWO\nTHREE"
               })

      assert File.read!(Path.join(dir, "a.ex")) == "one\nTWO\nTHREE\n"
    end

    test "pass 3 ignores indentation", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.ex"), "if x do\n    a()\n    b()\nend\n")

      assert {:ok, "edited a.ex: 1 replacement(s) (matched ignoring indentation)"} =
               edit(ctx, %{
                 "path" => "a.ex",
                 "old_string" => "a()\nb()",
                 "new_string" => "    c()\n    d()"
               })

      assert File.read!(Path.join(dir, "a.ex")) == "if x do\n    c()\n    d()\nend\n"
    end

    test "pass 4 normalises quotes, dashes and spaces", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.md"), "intro\nit\u00A0doesn\u2019t fit\noutro\n")

      assert {:ok, message} =
               edit(ctx, %{
                 "path" => "a.md",
                 "old_string" => "it doesn't fit",
                 "new_string" => "it fits"
               })

      assert message ==
               "edited a.md: 1 replacement(s) (matched after normalising quotes, dashes and spaces)"

      assert File.read!(Path.join(dir, "a.md")) == "intro\nit fits\noutro\n"
    end

    test "a CRLF file matches and stays CRLF", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.txt"), "alpha\r\nbeta\r\ngamma\r\n")

      assert {:ok, message} =
               edit(ctx, %{
                 "path" => "a.txt",
                 "old_string" => "alpha\nbeta",
                 "new_string" => "alpha\ndelta"
               })

      assert message =~ "(matched ignoring trailing whitespace)"
      assert File.read!(Path.join(dir, "a.txt")) == "alpha\r\ndelta\r\ngamma\r\n"
    end

    test "an ambiguous fuzzy match names its pass and changes nothing", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.txt"), "a  \nb\nmiddle\na \nb\n")

      assert {:error,
              "old_string matches 2 places in a.txt (ignoring trailing whitespace); " <>
                "provide more context or set replace_all=true"} =
               edit(ctx, %{"path" => "a.txt", "old_string" => "a\nb", "new_string" => "X\nY"})

      assert File.read!(Path.join(dir, "a.txt")) == "a  \nb\nmiddle\na \nb\n"
    end
  end

  describe "Ripgrep detection and the Elixir fallback (spec 70 C1, C3)" do
    setup do
      Ripgrep.reset_cache()
      on_exit(fn -> Ripgrep.reset_cache() end)
      dir = Fixtures.tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)
      File.write!(Path.join(dir, "hello.ex"), "defmodule Hello do\n  def greet, do: :hi\nend\n")
      File.write!(Path.join(dir, "world.txt"), "hello world\ngoodbye world\n")
      File.write!(Path.join(dir, "binary.bin"), <<0, 1, 2, 0xFF, 0xFE>>)
      {:ok, root: dir}
    end

    test "detection is cached and a reset re-detects" do
      first = Ripgrep.rg_path()
      assert is_binary(first) or is_nil(first)
      assert Ripgrep.available?() == (first != nil)
      assert is_boolean(Ripgrep.pcre2?())
      assert Ripgrep.rg_path() == first

      Ripgrep.reset_cache()
      :persistent_term.put({Ripgrep, :rg_path}, nil)
      :persistent_term.put({Ripgrep, :pcre2}, false)
      assert Ripgrep.rg_path() == nil
      refute Ripgrep.available?()

      Ripgrep.reset_cache()
      assert Ripgrep.rg_path() == first
    end

    test "grep answers the same with ripgrep and with the fallback", %{root: root} do
      if Ripgrep.available?() and Ripgrep.pcre2?() do
        {:ok, with_rg} = grep(root, %{"pattern" => "hello"})
        force_fallback()
        {:ok, fallback} = grep(root, %{"pattern" => "hello"})

        assert with_rg |> String.split("\n") |> Enum.sort() ==
                 fallback |> String.split("\n") |> Enum.sort()
      end
    end

    test "the fallback still finds matches and refuses an invalid regex", %{root: root} do
      force_fallback()
      assert {:ok, result} = grep(root, %{"pattern" => "hello"})
      assert result =~ "hello"
      assert {:error, message} = grep(root, %{"pattern" => "(unclosed"})
      assert message =~ "invalid regex"
    end
  end

  defp edit(ctx, args), do: Tools.run("edit_file", args, ctx, fn _, _ -> :ok end)

  defp grep(root, args), do: Tools.run("grep", args, %{project_root: root}, fn _, _ -> :ok end)

  defp force_fallback do
    Ripgrep.reset_cache()
    :persistent_term.put({Ripgrep, :rg_path}, nil)
    :persistent_term.put({Ripgrep, :pcre2}, false)
  end

  defp exchange(index, size) do
    [
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{id: "t#{index}", name: "read_file", args: %{"path" => "f#{index}"}}]
      },
      %{
        role: "tool",
        tool_call_id: "t#{index}",
        name: "read_file",
        content: String.duplicate("x", size),
        is_error: false
      }
    ]
  end
end
