defmodule SwarmCodeCLI.Cli020.E21SyntaxTest do
  # cli020 E21 (tui-code-10): a fence's block comment or multi-line string
  # carries across lines, and go, c/cpp, java, ruby, sql, yaml/toml and
  # html/css get keyword tables. Tokens still join back to the line.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Projector.Syntax

  defp kinds(tokens), do: Enum.map(tokens, &elem(&1, 1))

  defp kind_of(tokens, text),
    do: Enum.find_value(tokens, fn {t, k} -> if String.contains?(t, text), do: k end)

  defp joined!(lines, out) do
    for {line, tokens} <- Enum.zip(lines, out),
        do: assert(Enum.map_join(tokens, &elem(&1, 0)) == line)
  end

  test "a block comment carries across lines (js)" do
    lines = ["const a = 1; /* one", "two const three", "end */ const b = 2;"]
    out = Syntax.lines(lines, "js")
    joined!(lines, out)
    assert kinds(Enum.at(out, 1)) == [:comment]
    third = Enum.at(out, 2)
    assert kind_of(third, "end */") == :comment
    assert kind_of(third, "const") == :keyword
  end

  test "a triple-quoted string carries (python)" do
    lines = ["doc = \"\"\"first", "def not_code", "last\"\"\" if x else y"]
    out = Syntax.lines(lines, "python")
    joined!(lines, out)
    assert kinds(Enum.at(out, 1)) == [:string]
    assert kind_of(Enum.at(out, 2), "last") == :string
    assert kind_of(Enum.at(out, 2), "else") == :keyword
  end

  test "an elixir heredoc carries" do
    lines = ["@doc \"\"\"", "  def inside", "\"\"\"", "def outside"]
    out = Syntax.lines(lines, "elixir")
    joined!(lines, out)
    assert kinds(Enum.at(out, 1)) == [:string]
    assert kind_of(Enum.at(out, 3), "def") == :keyword
  end

  @samples %{
    "go" => {"func main() { return }", "func"},
    "c" => {"static int main(void) { return 0; }", "static"},
    "cpp" => {"namespace app { class A {}; }", "namespace"},
    "java" => {"public final class A extends B {}", "extends"},
    "ruby" => {"def run; unless x then nil end", "unless"},
    "sql" => {"SELECT id FROM users WHERE id = 1", "SELECT"},
    "yaml" => {"enabled: true", "true"},
    "toml" => {"enabled = false", "false"},
    "css" => {"a { color: red !important; }", "important"},
    "html" => {"<div class=\"x\">hi</div>", "div"}
  }

  for {lang, {line, keyword}} <- @samples do
    test "#{lang}: #{keyword} is a keyword" do
      out = Syntax.lines([unquote(line)], unquote(lang))
      joined!([unquote(line)], out)
      assert kind_of(hd(out), unquote(keyword)) == :keyword
    end
  end

  test "comments per language" do
    assert Syntax.lines(["-- a note"], "sql") == [[{"-- a note", :comment}]]
    assert Syntax.lines(["# a note"], "ruby") == [[{"# a note", :comment}]]
    assert Syntax.lines(["# a note"], "yaml") == [[{"# a note", :comment}]]
    assert Syntax.lines(["// a note"], "go") == [[{"// a note", :comment}]]
    assert kinds(hd(Syntax.lines(["<!-- a note -->"], "html"))) == [:comment]
  end

  test "an html comment carries" do
    out = Syntax.lines(["<!-- open", "<div>", "close --> <p>"], "html")
    assert kinds(Enum.at(out, 1)) == [:comment]
    assert kind_of(Enum.at(out, 2), "p") == :keyword
  end

  test "a yaml key is a type, a toml key too" do
    assert kind_of(hd(Syntax.lines(["name: ncode"], "yaml")), "name") == :type
    assert kind_of(hd(Syntax.lines(["name = \"ncode\""], "toml")), "name") == :type
  end

  test "byte bound unchanged: a long line is one plain token, and a comment stays open" do
    long = String.duplicate("x", 5_000)
    assert [[{^long, :plain}]] = Syntax.lines([long], "js")
    out = Syntax.lines(["/* open", long, "*/ const"], "js")
    assert kind_of(Enum.at(out, 2), "const") == :keyword
  end
end
