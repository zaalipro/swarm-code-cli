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
