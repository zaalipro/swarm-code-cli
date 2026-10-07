defmodule SwarmCodeCLI.UI.DataSource.DTO.DesktopPresence do
  @moduledoc """
  cli020 C4 (bugs-6): the body of the shell watch's `desktop_running` delta,
  whether the ncode app is open on the same database right now.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [running: :boolean],
    defaults: [running: false]
end
