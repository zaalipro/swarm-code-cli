defmodule SwarmCodeCLI.UI.Projector.Settings.Page do
  @moduledoc """
  The settings page as E draws it (pass 75): the rows of `Nav.rows/1` in
  groups that hang on a one-cell spine, each group opened by its title line
  (`╭─ title … tag`), groups separated by one blank line, the focused item on
  the band, and a window that follows the cursor by group. Pure: it reads the
  projector state (`state.settings`, `state.capabilities`), the frame's
  `Settings.Grid` and answers lines of segments exactly `grid.page.width`
  cells wide.
  """

  alias SwarmCodeCLI.UI.Projector.Settings.Text
  alias SwarmCodeCLI.UI.Settings.{Glyphs, Grid, Row}

  @type segments :: [Text.segment()]
  @type group :: %{
          title: segments() | nil,
          tag: segments(),
          rows: [Row.t()],
          spined?: boolean(),
          danger?: boolean(),
          first_index: non_neg_integer()
        }

  # ----------------------------------------------------------- groups

  @doc """
  The page's rows as groups: a heading row opens a group (its title and
  tag); leading info rows before the first heading form one group without a
  spine or title; other rows before the first heading form a title-less
  spined group; a blank info row ends the current group. A table's heading
  (a heading with columns) stays a row of its group.
  """
  @spec groups([Row.t()]) :: [group()]
  def groups(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce([], fn {row, index}, groups -> place(groups, row, index) end)
    |> Enum.map(fn group -> %{group | rows: Enum.reverse(group.rows)} end)
    |> Enum.reverse()
    |> Enum.reject(&(&1.title == nil and &1.rows == []))
  end

  defp place(groups, %Row{kind: :heading, columns: columns} = row, index)
       when columns in [nil, []] do
    [
      %{
        title: [{row.label, :text_muted}],
        tag: row.tag || [],
        rows: [],
        spined?: true,
        danger?: row.label == "danger",
        first_index: index
      }
      | groups
    ]
  end

  defp place(groups, %Row{} = row, index) do
    cond do
      blank?(row) ->
        [open(nil, true, index) | groups]

      groups == [] ->
        [%{open(nil, not info?(row), index) | rows: [row]}]

      true ->
        [group | rest] = groups

        if group.title == nil and not group.spined? and not info?(row),
          do: [%{open(nil, true, index) | rows: [row]}, group | rest],
          else: [%{group | rows: [row | group.rows]} | rest]
    end
  end

  defp open(title, spined?, index),
    do: %{title: title, tag: [], rows: [], spined?: spined?, danger?: false, first_index: index}

  defp info?(%Row{kind: :info}), do: true
  defp info?(_row), do: false

  # An info row with nothing to say separates what is above from what is below.
  defp blank?(%Row{kind: :info, label: "", value: value, lines: []}),
    do: Enum.all?(value, fn {text, _} -> String.trim(text) == "" end)

  defp blank?(_row), do: false

  @doc """
  A group's title line: `╭─ ` (faint), the title (muted) and its tag right
  aligned one cell inside the page's right edge (faint; a `warning` tag
  keeps its role). In the twin: `   title ----…   tag`.
  """
  @spec title_line(map(), group(), Grid.t()) :: segments()
  def title_line(state, %{title: title} = group, %Grid{page: page}) do
    caps = state.capabilities
    tag = Enum.map(group.tag, &faint_tag/1)
    right = if tag == [], do: [], else: tag ++ [{" ", :text_primary}]

    if Glyphs.twin?(caps) do
      left = [{"   ", :text_primary}] ++ title ++ [{" ", :text_primary}]
      stop = if tag == [], do: 4, else: Text.cells(state, right) + 3
      run = max(page.width - Text.cells(state, left) - stop, 0)
      line = left ++ [{String.duplicate(Glyphs.for_caps(:title_lead, caps), run), :text_faint}]
      Text.spread(state, line, right, page.width)
    else
      lead =
        Glyphs.for_caps(:spine_top, caps) <> Glyphs.for_caps(:title_lead, caps) <> " "

      Text.spread(state, [{lead, :text_faint} | title], right, page.width)
    end
  end

  defp faint_tag({text, role}) when role in [:warning, :error], do: {text, role}
  defp faint_tag({text, _role}), do: {text, :text_faint}

  @doc """
  The blank lines between groups: one before every group but the first
  (`true` = a blank line goes before that group), none after a title.
  """
  @spec separators([group()]) :: [boolean()]
  def separators(groups), do: groups |> Enum.with_index() |> Enum.map(fn {_, i} -> i > 0 end)

  # ----------------------------------------------- hoist and marks

  @prefixes [action: "▸ ", link: "→ ", running: "◐ "]

  @doc """
  A row as the page draws it: a leading `▸ `, `→ ` or `◐ ` (or the tier's
  twin) of its label, else of its first value segment, becomes the `:action`,
  `:link` or `:running` mark in the mark slot; a finished task's `✓ ` plus its
  muted summary becomes one `chip_ok` chip. The section's row data is not
  changed (D4).
  """
  @spec hoist(Row.t(), map()) :: Row.t()
  def hoist(%Row{} = row, caps) do
    prefixes = prefixes(caps)
    row |> hoist_prefix(prefixes) |> chip(caps)
  end

  defp prefixes(caps) do
    Enum.flat_map(@prefixes, fn {mark, prefix} ->
      twin = Glyphs.get(mark, :ascii) <> " "
      if Glyphs.tier(caps) == :ascii, do: [{mark, prefix}, {mark, twin}], else: [{mark, prefix}]
    end)
  end

  defp hoist_prefix(%Row{label: label, value: value} = row, prefixes) do
    case Enum.find(prefixes, fn {_, prefix} -> String.starts_with?(label, prefix) end) do
      {mark, prefix} ->
        %{row | label: String.replace_prefix(label, prefix, ""), marks: add_mark(row.marks, mark)}

      nil ->
        with [{text, role} | rest] <- value,
             true <- is_binary(text),
             {mark, prefix} <-
               Enum.find(prefixes, fn {_, prefix} -> String.starts_with?(text, prefix) end) do
          %{
            row
            | value: [{String.replace_prefix(text, prefix, ""), role} | rest],
              marks: add_mark(row.marks, mark)
          }
        else
          _ -> row
        end
    end
  end

  defp add_mark(marks, mark), do: if(mark in marks, do: marks, else: marks ++ [mark])

  defp chip(%Row{value: [{ok, :success}, {summary, :text_muted} | rest]} = row, caps)
       when ok in ["✓ ", "v "] do
    chip =
      if Glyphs.twin?(caps),
        do: {"[" <> ok <> summary <> "]", :success},
        else: {" " <> ok <> summary <> " ", :chip_ok}

    %{row | value: [chip | rest]}
  end

  defp chip(row, _caps), do: row

  @doc "Every ` · ` in a primary or muted segment drawn faint; the pieces keep their role."
  @spec split_dots(segments()) :: segments()
  def split_dots(segments) do
    Enum.flat_map(segments, fn
      {text, role} when role in [:text_primary, :text_muted] and is_binary(text) ->
        text
        |> String.split(" · ")
        |> Enum.intersperse(:dot)
        |> Enum.flat_map(fn
          :dot -> [{" · ", :text_faint}]
          "" -> []
          piece -> [{piece, role}]
        end)

      segment ->
        [segment]
    end)
  end

  @mark_order [:invalid, :conflict, :attention, :pending, :running, :action, :link]

  @doc """
  The one glyph of a row's mark slot, by priority; `:changed` draws nothing
  (the spine's hue says it). `danger?` draws the action mark as an error.
  """
  @spec mark(Row.t(), map(), boolean()) :: Text.segment()
  def mark(%Row{marks: marks}, caps, danger?) do
    glyph = &Glyphs.for_caps(&1, caps)

    case Enum.find(@mark_order, &(&1 in marks)) || Enum.find(marks, &swatch?/1) do
      :invalid -> {glyph.(:fail), :error}
      :conflict -> {"!", :warning}
      :attention -> {"!", {:warning, [:bold]}}
      :pending -> {glyph.(:running), :text_faint}
      :running -> {glyph.(:running), :info}
      :action -> {glyph.(:action), if(danger?, do: :error, else: :text_muted)}
      :link -> {glyph.(:link), :text_muted}
      {:swatch, texture, role} -> {glyph.(texture), role}
      nil -> {" ", :text_primary}
    end
  end

  defp swatch?({:swatch, _texture, _role}), do: true
  defp swatch?(_mark), do: false

  @doc """
  A label without the ` · <group title>` it ends with (`Model · this
  conversation` under `this conversation` draws `Model`); the registry label
  is untouched.
  """
  @spec strip_suffix(String.t(), String.t() | nil) :: String.t()
  def strip_suffix(label, title) when is_binary(title) and title != "" do
    suffix = " · " <> title

    if String.ends_with?(label, suffix) and label != suffix,
      do: String.replace_suffix(label, suffix, ""),
      else: label
  end

  def strip_suffix(label, _title), do: label
end
