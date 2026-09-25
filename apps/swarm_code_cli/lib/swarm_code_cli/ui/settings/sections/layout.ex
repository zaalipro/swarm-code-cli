defmodule SwarmCodeCLI.UI.Settings.Sections.Layout do
  @moduledoc """
  pass74 U3-10 (spec §2.15): Layout & transcript — this terminal's cli.json
  values: the side panel, the composer's height at launch, the inspector's
  width, diffs on or off, how long notices stay, and how many lines of a
  diff hunk the transcript draws before `… N more lines`. Every row applies
  at once (the reducer's live consumers, §3.8.5); nothing needs the service,
  so the page works in unsaved sessions too.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :layout

  alias SwarmCodeCLI.UI.Settings.{Row, Rows}

  @impl true
  def loads(_ctx), do: []

  @impl true
  def rows(ctx) do
    ctx
    |> Rows.registry(:layout)
    |> Enum.map(fn
      %Row{key: "terminal.show_diffs"} = row ->
        %Row{row | lines: row.lines ++ [[{"/diff on|off does the same", :text_faint}]]}

      %Row{key: "terminal.panel"} = row ->
        %Row{row | lines: row.lines ++ [[{"Ctrl-B cycles it · /panel", :text_faint}]]}

      row ->
        row
    end)
  end
end
