defmodule SwarmCodeCLI.UI.Settings.Sections.DesktopApp do
  @moduledoc """
  pass74 U3-11 (spec §2.20): the desktop app's own settings, shared through
  the database; the terminal ignores them (except Mode, which the terminal's
  Theme can follow). Every row says `no effect in the terminal`. The window
  state the desktop writes as you drag is one collapsed row that opens a
  sub-page. The desktop's shortcuts use the key-capture editor in desktop
  mode (⌘ cannot reach a terminal: Ctrl stands in, or `t` types a combo);
  `▸ Reset all desktop keys` puts every one back.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :desktop

  alias SwarmCode.Settings.{Entry, Registry}
  alias SwarmCodeCLI.UI.Settings.{Page, Row, Rows}
  alias SwarmCodeCLI.UI.Settings.Editors.KeyCapture

  @window "window state"
  @intro "These change the desktop app. The terminal ignores them (except Mode, which Theme can follow)."

  @impl true
  def rows(ctx) do
    rows = ctx |> Rows.registry(:desktop) |> Enum.map(&decorate(&1, ctx))
    {window, rest} = split_window(rows)
    keys = desktop_keys(rows)

    [Row.info("desktop-intro", @intro, role: :text_muted)] ++
      insert_reset(rest, keys) ++ window_row(window)
  end

  @impl true
  def sub_rows(ctx, :window_state) do
    {window, _rest} =
      ctx |> Rows.registry(:desktop) |> Enum.map(&decorate(&1, ctx)) |> split_window()

    [
      Row.info(
        "window-intro",
        "the desktop writes these as you drag; editing them here is rarely useful",
        role: :text_faint
      )
      | Enum.reject(window, &(&1.kind == :heading))
    ]
  end

  def sub_rows(_ctx, _sub), do: []

  @impl true
  def act(_ctx, %Row{id: "act:window_state"}, verb) when verb in [:open, :enter, :open_row],
    do: [{:open, %Page{section: :desktop, sub: :window_state}}]

  def act(ctx, %Row{id: "act:reset_desktop_keys"}, verb)
      when verb in [:open, :enter, :open_row] do
    keys = ctx |> Rows.registry(:desktop) |> desktop_keys()
    [{:reset, keys}, {:toast, "Desktop keys back to their defaults", :success}]
  end

  def act(_ctx, _row, _verb), do: :default

  # ------------------------------------------------------------------ rows

  defp decorate(%Row{key: "desktop.keys." <> action} = row, _ctx),
    do: %Row{row | editor: {KeyCapture, %{mode: :desktop, action: action, label: row.label}}}

  # The CLI writes the desktop's values too (§2.20): `Rows.editor/4` gives
  # desktop-only entries none, so their editor is built as a shared entry's.
  defp decorate(%Row{key: key, editor: nil} = row, ctx) when is_binary(key) do
    with {:ok, %Entry{desktop_only: true} = entry} <- Registry.fetch(key),
         setting when not is_nil(setting) <- Rows.setting(ctx, entry) do
      shared = %{entry | desktop_only: false}
      %Row{row | editor: Rows.editor(ctx, shared, Rows.shown(ctx, shared, setting), setting)}
    else
      _ -> row
    end
  end

  defp decorate(row, _ctx), do: row

  defp split_window(rows) do
    {window, rest, _in_window?} =
      Enum.reduce(rows, {[], [], false}, fn
        %Row{kind: :heading, label: @window} = row, {w, r, _} -> {[row | w], r, true}
        %Row{kind: :heading} = row, {w, r, _} -> {w, [row | r], false}
        row, {w, r, true} -> {[row | w], r, true}
        row, {w, r, false} -> {w, [row | r], false}
      end)

    {Enum.reverse(window), Enum.reverse(rest)}
  end

  defp window_row([]), do: []

  defp window_row(window) do
    count = Enum.count(window, &(&1.kind != :heading))
    changed = Enum.count(window, &(:changed in &1.marks))

    [
      Row.heading(@window),
      %Row{
        id: "act:window_state",
        kind: :action,
        label: "Window state",
        value: [{"#{count} values · #{changed} changed", :text_muted}],
        tag: [{"Enter shows them", :text_faint}],
        keys: [{"Enter", :enter, "show them"}]
      }
    ]
  end

  defp desktop_keys(rows),
    do: for(%Row{key: "desktop.keys." <> _ = key} <- rows, do: key)

  defp insert_reset(rows, []), do: rows

  defp insert_reset(rows, keys) do
    last = rows |> Enum.with_index() |> Enum.filter(fn {r, _} -> r.key in keys end) |> List.last()

    reset = %Row{
      id: "act:reset_desktop_keys",
      kind: :action,
      label: "Reset all desktop keys",
      value: [{"#{length(keys)} shortcuts back to the desktop's defaults", :text_muted}],
      keys: [{"Enter", :enter, "reset them"}]
    }

    case last do
      nil -> rows ++ [reset]
      {_, index} -> List.insert_at(rows, index + 1, reset)
    end
  end
end
