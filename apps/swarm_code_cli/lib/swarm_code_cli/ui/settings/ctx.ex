defmodule SwarmCodeCLI.UI.Settings.Ctx do
  @moduledoc """
  Everything a section or an editor may read (spec §3.7.2), assembled by
  `Reducer.Settings` from the state. Pure data: no clock but `now`, no ids of
  its own, no IO.

    * `state_view` — the few shell facts settings shows (workspace metadata,
      the needs-you count, the keymap, the live terminal preferences).
    * `data` — `Settings.Data`: what the service answered.
    * `caps`, `size`, `now` — the terminal and the owner's clock.
    * `project`, `conversation` — the page's project (the picker's choice, or
      the session's) and the session conversation id.
    * `prefs` — every cli.json value by json name (`state.prefs`).
    * `launch_facts` — env and flag overrides and the launch flags.
    * `overrides` — the compiled key overrides (`Keymap.Overrides`).
    * `layer`, `page` — the layer and the page being built (read-only).
  """

  defstruct state_view: %{},
            data: nil,
            caps: nil,
            size: nil,
            now: 0,
            project: nil,
            conversation: nil,
            prefs: %{},
            launch_facts: %{},
            overrides: nil,
            layer: nil,
            page: nil

  @type t :: %__MODULE__{}
end
