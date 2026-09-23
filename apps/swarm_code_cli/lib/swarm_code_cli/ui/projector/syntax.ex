defmodule SwarmCodeCLI.UI.Projector.Syntax do
  @moduledoc """
  A small line tokenizer for code blocks: enough colour to read the shape of
  elixir, js/ts, python, rust, shell, json and diffs at a glance, never a
  parser. Each line becomes `{text, kind}` tokens whose texts concatenate back
  to the line exactly; kind is one of `:plain`, `:keyword`, `:string`,
  `:number`, `:comment`, `:type`, `:atom`, `:function`, `:punct`, `:variable`,
  `:add`, `:del`, `:hunk` and `:meta`. State does not cross lines, so a
  multi-line string or block comment colours only its first and last lines
  correctly; that is the price of a stateless, bounded tokenizer.
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
    json: ~w(true false null)
  }

  @spec lines([binary()], binary()) :: [[{binary(), kind()}]]
  def lines(lines, language) do
    lang = language(language)
    Enum.map(lines, &line(&1, lang))
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
      _ -> :plain
    end
  end

  @spec line(binary(), atom()) :: [{binary(), kind()}]
  def line(text, _lang) when byte_size(text) > @line_bytes, do: [{text, :plain}]
  def line("", _lang), do: []
  def line(text, :plain), do: [{text, :plain}]
  def line(text, :diff), do: [{text, diff_kind(text)}]
  def line(text, lang), do: text |> tokens(lang, []) |> merge()

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

  defp comment(text, lang) when lang in [:elixir, :python, :shell] do
    if String.starts_with?(text, "#") and not String.starts_with?(text, "\#{"), do: text
  end

  defp comment(text, lang) when lang in [:js, :rust] do
    cond do
      String.starts_with?(text, "//") -> text
      String.starts_with?(text, "/*") -> block_comment(text)
      true -> nil
    end
  end

  defp comment(_text, _lang), do: nil

  defp block_comment(text) do
    case :binary.match(text, "*/", scope: {2, byte_size(text) - 2}) do
      {at, 2} -> binary_part(text, 0, at + 2)
      :nomatch -> text
    end
  end

  defp string(text, lang) do
    quotes =
      case lang do
        :js -> ["\"", "'", "`"]
        :python -> ["\"", "'"]
        :shell -> ["\"", "'"]
        :rust -> ["\""]
        _ -> ["\""]
      end

    case Enum.find(quotes, &String.starts_with?(text, &1)) do
      nil -> sigil(text, lang)
      quote_char -> quoted(text, quote_char)
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

      name in Map.fetch!(@keywords, lang) ->
        {name, :keyword}

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
