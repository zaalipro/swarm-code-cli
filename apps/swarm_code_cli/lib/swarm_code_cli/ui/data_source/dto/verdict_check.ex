defmodule SwarmCodeCLI.UI.DataSource.DTO.VerdictCheck do
  @moduledoc "One judged criterion; `ok` is unknown until the judge scores it."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [ok: nil, note: ""],
    fields: [key: {:text, 200}, ok: {:optional, :boolean}, note: {:text, 400}],
    defaults: [key: "", ok: nil, note: ""]
end
