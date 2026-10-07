defmodule SwarmCodeCLI.UI.Projector.Syntax do
  @moduledoc """
  A small line tokenizer for code blocks: enough colour to read the shape of
  elixir, js/ts, python, rust, shell, json and diffs at a glance, never a
  parser. Each line becomes `{text, kind}` tokens whose texts concatenate back
  to the line exactly; kind is one of `:plain`, `:keyword`, `:string`,
  `:number`, `:comment`, `:type`, `:atom`, `:function`, `:punct`, `:variable`,
  `:add`, `:del`, `:hunk` and `:meta`.

  cli020 E21 (tui-code-10): `lines/2` carries one fact from line to line
  of a fence: inside a block comment (`/* */`, `<!-- -->`) or a multi-line
  string (triple quotes, a backtick), so the lines between colour as what
  they are. Go, C/C++, Java, Ruby, SQL, YAML/TOML and HTML/CSS have keyword
  tables. The byte bound per line is unchanged.
  """

  @type kind ::
          :plain
          | :keyword
          | :string
          | :number
          | :comment
          | :type
          | :atom
          | :function
          | :punct
          | :variable
          | :add
          | :del
          | :hunk
          | :meta

  # A line longer than this is one plain token.
  @line_bytes 4_096

  @keywords %{
    elixir:
      ~w(def defp defmodule defmacro defmacrop defstruct defimpl defprotocol defguard defdelegate do end fn case cond with if else unless when import alias use require quote unquote receive after try rescue catch raise true false nil and or not in for),
    js:
      ~w(const let var function return if else for while do class new import from export default async await try catch finally throw typeof instanceof null undefined true false this interface type extends implements enum switch case break continue of in yield static public private protected readonly as),
    python:
      ~w(def class return if elif else for while in import from as with try except finally raise lambda None True False and or not is pass break continue yield async await global nonlocal assert del self),
    rust:
      ~w(fn let mut pub struct enum impl trait use mod match if else for while loop return self Self crate super where as const static ref move async await dyn true false in type unsafe extern),
    shell:
      ~w(if then else elif fi for do done while until case esac function in export local return echo cd set unset source exit),
    json: ~w(true false null),
    go:
      ~w(break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota),
    c:
      ~w(auto break case char const continue default do double else enum extern float for goto if inline int long register return short signed sizeof static struct switch typedef union unsigned void volatile while NULL true false bool),
    cpp:
      ~w(auto break case char const continue default do double else enum extern float for goto if inline int long register return short signed sizeof static struct switch typedef union unsigned void volatile while NULL true false bool class namespace template typename public private protected virtual override new delete this using try catch throw nullptr constexpr friend operator explicit noexcept),
    java:
      ~w(abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for if implements import instanceof int interface long native new package private protected public return short static super switch synchronized this throw throws transient try void volatile while true false null var record),
    ruby:
      ~w(def end class module if elsif else unless while until for in do return yield begin rescue ensure raise then case when nil true false self and or not require include extend attr_accessor attr_reader attr_writer lambda proc super next break redo retry),
    sql:
      ~w(SELECT FROM WHERE AND OR NOT INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE DROP ALTER INDEX JOIN LEFT RIGHT INNER OUTER ON AS GROUP BY ORDER HAVING LIMIT OFFSET NULL IS IN LIKE DISTINCT UNION ALL PRIMARY KEY FOREIGN REFERENCES DEFAULT CASE WHEN THEN ELSE END EXISTS BETWEEN TRUE FALSE WITH RETURNING ASC DESC COUNT),
    yaml: ~w(true false null yes no on off),
    toml: ~w(true false),
    css: ~w(important inherit initial unset auto none),
    html: ~w(DOCTYPE)
  }

  # cli020 E21: where a comment or a string may run past its line.
  @block_comments %{
    js: {"/*", "*/"},
    rust: {"/*", "*/"},
    go: {"/*", "*/"},
    c: {"/*", "*/"},
    cpp: {"/*", "*/"},
    java: {"/*", "*/"},
    sql: {"/*", "*/"},
    css: {"/*", "*/"},
    html: {"<!--", "-->"}
  }

  @line_comments %{
    elixir: ["#"],
    python: ["#"],
    shell: ["#"],
    ruby: ["#"],
    yaml: ["#"],
    toml: ["#"],
    js: ["//"],
    rust: ["//"],
    go: ["//"],
    c: ["//"],
    cpp: ["//"],
    java: ["//"],
    sql: ["--"]
  }

  @quotes %{
    js: ["\"", "'", "`"],
    python: ["\"", "'"],
    shell: ["\"", "'"],
    go: ["\"", "'", "`"],
    c: ["\"", "'"],
    cpp: ["\"", "'"],
    java: ["\"", "'"],
    ruby: ["\"", "'"],
    sql: ["'", "\""],
    yaml: ["\"", "'"],
    toml: ["\"", "'"],
    css: ["\"", "'"],
    html: ["\"", "'"]
  }

  @triple ["\"\"\"", "'''"]
  @multiline %{python: @triple, elixir: @triple, toml: @triple, js: ["`"], go: ["`"]}

  @spec lines([binary()], binary()) :: [[{binary(), kind()}]]
  def lines(lines, language) do
    lang = language(language)
    {out, _carry} = Enum.map_reduce(lines, nil, &line(&1, lang, &2))
    out
  end

  @spec language(binary()) :: atom()
  def language(name) do
    case String.downcase(name || "") do
      l when l in ["elixir", "ex", "exs", "iex", "heex", "eex"] -> :elixir
      l when l in ["js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs"] -> :js
      l when l in ["py", "python", "python3"] -> :python
      l when l in ["rs", "rust"] -> :rust
      l when l in ["sh", "bash", "zsh", "shell", "console", "fish"] -> :shell
      l when l in ["json", "jsonc"] -> :json
      l when l in ["diff", "patch"] -> :diff
      l when l in ["go", "golang"] -> :go
      l when l in ["c", "h"] -> :c
      l when l in ["cpp", "c++", "cc", "cxx", "hpp", "hh"] -> :cpp
      l when l in ["java"] -> :java
      l when l in ["ruby", "rb"] -> :ruby
      l when l in ["sql", "psql", "sqlite", "mysql", "postgresql"] -> :sql
      l when l in ["yaml", "yml"] -> :yaml
      l when l in ["toml"] -> :toml
      l when l in ["css", "scss", "less"] -> :css
      l when l in ["html", "htm", "xml", "svg", "vue"] -> :html
      _ -> :plain
    end
  end

  @spec line(binary(), atom()) :: [{binary(), kind()}]
  def line(text, lang), do: text |> line(lang, nil) |> elem(0)

  # `carry` is nil or `{:comment | :string, close}`: what the line starts
  # inside of. A line past the byte bound is one token of what it is in.
  defp line(text, _lang, carry) when byte_size(text) > @line_bytes,
    do: {[{text, carried_kind(carry)}], carry}

  defp line("", _lang, carry), do: {[], carry}
  defp line(text, :plain, carry), do: {[{text, :plain}], carry}
  defp line(text, :diff, carry), do: {[{text, diff_kind(text)}], carry}

  defp line(text, lang, carry) do
    case resume(text, carry) do
      {head, "", carry} ->
        {merge(head), carry}

      {head, rest, nil} ->
        tokens = tokens(rest, lang, [])
        {merge(head ++ tokens), opened(List.last(tokens), lang)}
    end
  end

  defp carried_kind({kind, _close}), do: kind
  defp carried_kind(nil), do: :plain

  defp resume(text, nil), do: {[], text, nil}

  defp resume(text, {kind, close} = carry) do
    case :binary.match(text, close) do
      {at, size} ->
        cut = at + size
        {[{binary_part(text, 0, cut), kind}], binary_part(text, cut, byte_size(text) - cut), nil}

      :nomatch ->
        {[{text, kind}], "", carry}
    end
  end

  # What the line's last token leaves open: a block comment without its
  # close, a multi-line string without its closing delimiter.
  defp opened({piece, :comment}, lang) do
    case Map.get(@block_comments, lang) do
      {open, close} ->
        if String.starts_with?(piece, open) and not closes?(piece, open, close),
          do: {:comment, close}

      nil ->
        nil
    end
  end

  defp opened({piece, :string}, lang) do
    @multiline
    |> Map.get(lang, [])
    |> Enum.find_value(fn delim ->
      if String.starts_with?(piece, delim) and not closes?(piece, delim, delim),
        do: {:string, delim}
    end)
  end

  defp opened(_token, _lang), do: nil

  defp closes?(piece, open, close),
    do: byte_size(piece) >= byte_size(open) + byte_size(close) and String.ends_with?(piece, close)

  defp diff_kind("+++" <> _), do: :meta
  defp diff_kind("---" <> _), do: :meta
  defp diff_kind("+" <> _), do: :add
  defp diff_kind("-" <> _), do: :del
  defp diff_kind("@@" <> _), do: :hunk
  defp diff_kind(_), do: :plain

  # --- scanning ----------------------------------------------------------------

  defp tokens("", _lang, acc), do: Enum.reverse(acc)

  defp tokens(text, lang, acc) do
    case token(text, lang) do
      {piece, kind} ->
        size = byte_size(piece)
        tokens(binary_part(text, size, byte_size(text) - size), lang, [{piece, kind} | acc])
    end
  end

  defp token(text, lang) do
    cond do
      comment = comment(text, lang) ->
        {comment, :comment}

      string = string(text, lang) ->
        {string, string_kind(string, text, lang)}

      match = Regex.run(~r/^\s+/, text) ->
        {hd(match), :plain}

      # cli020 E21: an HTML tag with its bracket (`<div`, `</p`).
      tag = html_tag(text, lang) ->
        {tag, :keyword}

      match = Regex.run(~r/^(0x[0-9a-fA-F_]+|\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d+)?)/, text) ->
        {hd(match), :number}

      atom = atom(text, lang) ->
        {atom, :atom}

      variable = variable(text, lang) ->
        {variable, :variable}

      match = Regex.run(~r/^[\p{L}_][\p{L}\p{N}_]*[?!]?/u, text) ->
        word(hd(match), text, lang)

      match = Regex.run(~r/^[^\s\p{L}\p{N}_"'`#]+/u, text) ->
        {hd(match), :punct}

      true ->
        {String.first(text), :plain}
    end
  end

  defp html_tag(text, :html) do
    case Regex.run(~r/^<\/?[A-Za-z][\w-]*/, text) do
      [tag] -> tag
      nil -> nil
    end
  end

  defp html_tag(_text, _lang), do: nil

  defp comment(text, lang) do
    line = Enum.find(Map.get(@line_comments, lang, []), &String.starts_with?(text, &1))
    block = Map.get(@block_comments, lang)

    cond do
      line == "#" and lang == :elixir and String.starts_with?(text, "\#{") -> nil
      line != nil -> text
      block != nil and String.starts_with?(text, elem(block, 0)) -> block_comment(text, block)
      true -> nil
    end
  end

  defp block_comment(text, {open, close}) do
    from = byte_size(open)

    case :binary.match(text, close, scope: {from, byte_size(text) - from}) do
      {at, size} -> binary_part(text, 0, at + size)
      :nomatch -> text
    end
  end

  defp string(text, lang) do
    triple =
      Enum.find(
        Map.get(@multiline, lang, []),
        &(byte_size(&1) == 3 and String.starts_with?(text, &1))
      )

    quotes = Map.get(@quotes, lang, ["\""])

    cond do
      triple != nil ->
        case :binary.match(text, triple, scope: {3, byte_size(text) - 3}) do
          {at, 3} -> binary_part(text, 0, at + 3)
          :nomatch -> text
        end

      quote_char = Enum.find(quotes, &String.starts_with?(text, &1)) ->
        quoted(text, quote_char)

      true ->
        sigil(text, lang)
    end
  end

  defp sigil("~" <> rest = text, :elixir) do
    case Regex.run(~r/^[a-zA-Z]+([\/|"'(\[{<])/, rest, capture: :all_but_first) do
      [open] ->
        close = Map.get(%{"(" => ")", "[" => "]", "{" => "}", "<" => ">"}, open, open)
        head = byte_size(hd(Regex.run(~r/^[a-zA-Z]+/, rest))) + 1

        case :binary.match(text, close, scope: {head + 1, byte_size(text) - head - 1}) do
          {at, 1} ->
            modifiers =
              Regex.run(~r/^[a-zA-Z]*/, binary_part(text, at + 1, byte_size(text) - at - 1))

            binary_part(text, 0, at + 1 + byte_size(hd(modifiers)))

          :nomatch ->
            text
        end

      _ ->
        nil
    end
  end

  defp sigil(_text, _lang), do: nil

  # A JSON string followed by a colon is a key.
  defp string_kind(string, text, :json) do
    rest = binary_part(text, byte_size(string), byte_size(text) - byte_size(string))
    if String.starts_with?(String.trim_leading(rest), ":"), do: :type, else: :string
  end

  defp string_kind(_string, _text, _lang), do: :string

  # A quoted string up to its unescaped closing quote, or the rest of the line.
  defp quoted(text, quote_char), do: quoted(text, quote_char, 1)

  defp quoted(text, quote_char, at) do
    case :binary.match(text, [quote_char, "\\"], scope: {at, byte_size(text) - at}) do
      :nomatch ->
        text

      {pos, 1} ->
        if binary_part(text, pos, 1) == "\\",
          do: if(pos + 2 <= byte_size(text), do: quoted(text, quote_char, pos + 2), else: text),
          else: binary_part(text, 0, pos + 1)
    end
  end

  defp atom(":" <> rest, :elixir) do
    case Regex.run(~r/^[a-zA-Z_][\w]*[?!]?/, rest) do
      [name] -> ":" <> name
      nil -> nil
    end
  end

  defp atom(_text, _lang), do: nil

  defp variable("$" <> rest, :shell) do
    case Regex.run(~r/^(\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@#?*!$-])/, rest) do
      [name | _] -> "$" <> name
      nil -> nil
    end
  end

  defp variable("@" <> rest, :python) do
    case Regex.run(~r/^[A-Za-z_][\w.]*/, rest) do
      [name] -> "@" <> name
      nil -> nil
    end
  end

  defp variable("@" <> rest, :elixir) do
    case Regex.run(~r/^[a-z_][\w]*/, rest) do
      [name] -> "@" <> name
      nil -> nil
    end
  end

  defp variable(_text, _lang), do: nil

  defp word(name, text, lang) do
    after_name = binary_part(text, byte_size(name), byte_size(text) - byte_size(name))

    cond do
      lang == :json ->
        {name, if(name in @keywords.json, do: :keyword, else: :plain)}

      lang == :sql and String.upcase(name) in @keywords.sql ->
        {name, :keyword}

      name in Map.fetch!(@keywords, lang) ->
        {name, :keyword}

      # cli020 E21: a YAML/CSS key before its colon, a TOML key before `=`.
      lang in [:yaml, :css] and String.starts_with?(String.trim_leading(after_name), ":") ->
        {name, :type}

      lang == :toml and String.starts_with?(String.trim_leading(after_name), "=") ->
        {name, :type}

      lang == :elixir and String.starts_with?(after_name, ":") and
          not String.starts_with?(after_name, "::") ->
        {name <> ":", :atom}

      lang == :rust and String.starts_with?(after_name, "!") ->
        {name <> "!", :function}

      Regex.match?(~r/^\p{Lu}/u, name) ->
        {name, :type}

      String.starts_with?(after_name, "(") ->
        {name, :function}

      true ->
        {name, :plain}
    end
  end

  defp merge(tokens) do
    tokens
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map(fn [{_, kind} | _] = group -> {Enum.map_join(group, &elem(&1, 0)), kind} end)
  end
end
