defmodule SwarmCodeCLI.UI.Renderer.Decision.Reason do
  @moduledoc "Closed rejection or future-candidate requirement, with an inert source reference."

  @enforce_keys [:code, :message, :source]
  defstruct [:code, :message, :source]

  @type code ::
          :unbounded_native_paste
          | :narrow_only_width
          | :no_public_no_alt
          | :arm64_jammy_abi
          | :target_gate_failed
          | :separate_plan_required
          | :declared_width_paint_plan_required
          | :guarded_port_required
          | :bounded_parser_required
          | :four_target_evidence_required
          | :exact_cell_renderer_required

  @type t :: %__MODULE__{code: code(), message: binary(), source: binary()}
end
