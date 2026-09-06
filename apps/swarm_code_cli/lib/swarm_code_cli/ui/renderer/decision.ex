defmodule SwarmCodeCLI.UI.Renderer.Decision do
  @moduledoc """
  Pure evaluation of renderer rejection evidence on the locked neutral branch.

  Accepts at most 64 inert JSON-shaped records. Static Gate-0 records must have
  exactly the documented version-1 fields, pinned identities, a UTC timestamp,
  and one to four distinct, closed veto codes with nonempty UTF-8 source strings
  of at most 4096 bytes. This validates the DTO, not the truth of a source claim:
  the caller must verify the immutable sources before publishing the record.

  The only other DTO has exactly `schema_version: 1`, `kind: "target_observation"`,
  `candidate`, `target`, and `result: "pass" | "fail"` (all keys are strings).
  Candidate names and the four target names are closed. A failure rejects only
  its candidate. A pass is an observation, never evidence of a verified campaign.

  Static vetoes precede target failures and missing or malformed observations.
  Unknown/malformed records cannot authorize adoption. No candidate has a vetted
  full-gate verification schema on this branch, so `:adopt` is intentionally
  unreachable until a separately planned implementation supplies that authority.
  This module neither reads files nor loads a renderer nor touches a terminal.
  """

  alias SwarmCodeCLI.UI.Renderer.Decision.Reason

  @type candidate :: :ex_ratatui_013 | :ratatui_port | :pure_elixir
  @type evidence_record :: map()
  @type result ::
          {:reject, candidate(), [Reason.t()]}
          | {:candidate, candidate(), [Reason.t()]}
          | {:adopt, candidate()}
          | {:incomplete, candidate(), [binary()]}

  @candidates [:ex_ratatui_013, :ratatui_port, :pure_elixir]
  @candidate_names %{
    ex_ratatui_013: "ex_ratatui_013",
    ratatui_port: "ratatui_port",
    pure_elixir: "pure_elixir"
  }
  @targets [
    "macos-arm64",
    "macos-x86_64",
    "ubuntu-22.04-arm64",
    "ubuntu-22.04-x86_64"
  ]
  @static_identity %{
    "schema_version" => 1,
    "candidate" => "ex_ratatui_013",
    "result" => "reject",
    "hex_inner_sha256" => "5b9a488a8b895b06cef782ba47effd3a7e03a675d0f44d70277349ad70326671",
    "hex_outer_sha256" => "0448833a5de5aed13fb480f57278deefe1ca3ff62af0d32e64515f4af674c030",
    "tag_object" => "e47964edac37e776ee8c43bd53241083b0aa8813",
    "source_commit" => "aa68bfc36016d90d6b1317f1f5edc8c4a6f9d045",
    "ratatui_commit" => "e665c36cb14752a61cd777fbd06dbef8474f2add",
    "crossterm_commit" => "36d95b26a26e64b0f8c12edfe11f410a6d56a812"
  }
  @vetoes [
    {"unbounded_native_paste", :unbounded_native_paste,
     "Native paste allocates before the project can bound input."},
    {"narrow_only_width", :narrow_only_width,
     "Physical text layout cannot honor the selected ambiguous-width policy."},
    {"no_public_no_alt", :no_public_no_alt,
     "Public initialization does not support no-alternate-screen operation."},
    {"arm64_jammy_abi", :arm64_jammy_abi,
     "The published arm64 GNU artifact exceeds the Ubuntu 22.04 ABI floor."}
  ]
  @veto_codes Enum.map(@vetoes, &elem(&1, 0))
  @full_gate_missing "candidate-specific full-gate verification is not implemented"

  @spec evaluate(candidate(), [evidence_record()]) :: result()
  def evaluate(candidate, evidence) when candidate in @candidates do
    case bounded_records(evidence, 64) do
      {:ok, records} -> evaluate_records(candidate, records)
      :error -> {:incomplete, candidate, ["evidence must be a proper list of at most 64 records"]}
    end
  end

  def evaluate(_candidate, _evidence), do: raise(ArgumentError, "unknown renderer candidate")

  @doc "Lists separately planned alternatives after exact-candidate rejection; never adopts one."
  @spec next_candidates(result()) :: [result()]
  def next_candidates({:reject, :ex_ratatui_013, [_ | _]}) do
    [
      {:candidate, :ratatui_port,
       [
         requirement(
           :separate_plan_required,
           "A separately reviewed candidate plan is required."
         ),
         requirement(
           :declared_width_paint_plan_required,
           "PaintPlan must physically honor declared cell widths."
         ),
         requirement(
           :guarded_port_required,
           "A credit-controlled Port, explicit /dev/tty and external restoration guard are required."
         ),
         requirement(
           :bounded_parser_required,
           "Input must be bounded while read, before allocation."
         ),
         requirement(
           :four_target_evidence_required,
           "All four targets must pass their own full gates."
         )
       ]},
      {:candidate, :pure_elixir,
       [
         requirement(
           :separate_plan_required,
           "A separately reviewed candidate plan is required."
         ),
         requirement(
           :exact_cell_renderer_required,
           "A project-owned exact-cell renderer and input implementation are required."
         ),
         requirement(
           :bounded_parser_required,
           "Input must be bounded while read, before allocation."
         ),
         requirement(
           :four_target_evidence_required,
           "All four targets must pass their own full gates."
         )
       ]}
    ]
  end

  def next_candidates(_result), do: []

  defp evaluate_records(candidate, records) do
    static = static_reasons(candidate, records)
    observations = Enum.filter(records, &target_observation?(&1, candidate))
    failed = target_failures(observations)

    cond do
      static != [] -> {:reject, candidate, static}
      failed != [] -> {:reject, candidate, failed}
      true -> {:incomplete, candidate, missing_observations(observations)}
    end
  end

  defp static_reasons(:ex_ratatui_013, records) do
    vetoes = records |> Enum.filter(&static_record?/1) |> Enum.flat_map(& &1["vetoes"])

    Enum.flat_map(@vetoes, fn {name, code, message} ->
      case vetoes |> Enum.filter(&(&1["code"] == name)) |> Enum.sort_by(& &1["source"]) do
        [veto | _] -> [%Reason{code: code, message: message, source: veto["source"]}]
        [] -> []
      end
    end)
  end

  defp static_reasons(_candidate, _records), do: []

  defp static_record?(record) when is_map(record) do
    map_size(record) == map_size(@static_identity) + 2 and
      Enum.all?(@static_identity, fn {key, value} -> Map.get(record, key) === value end) and
      utc_timestamp?(record["observed_at"]) and valid_vetoes?(record["vetoes"])
  end

  defp static_record?(_record), do: false

  defp utc_timestamp?(value) when is_binary(value) and byte_size(value) <= 40 do
    case DateTime.from_iso8601(value) do
      {:ok, _timestamp, 0} -> true
      _ -> false
    end
  end

  defp utc_timestamp?(_value), do: false

  defp valid_vetoes?(values) do
    case bounded_records(values, 4) do
      {:ok, [_ | _] = vetoes} ->
        Enum.all?(vetoes, &valid_veto?/1) and
          length(Enum.uniq_by(vetoes, & &1["code"])) == length(vetoes)

      _ ->
        false
    end
  end

  defp valid_veto?(%{"code" => code, "source" => source} = veto)
       when map_size(veto) == 2 and code in @veto_codes and is_binary(source) and
              byte_size(source) in 1..4096,
       do: String.valid?(source) and String.trim(source) != ""

  defp valid_veto?(_veto), do: false

  defp target_observation?(
         %{
           "schema_version" => 1,
           "kind" => "target_observation",
           "candidate" => name,
           "target" => target,
           "result" => result
         } = record,
         candidate
       )
       when map_size(record) == 5 and target in @targets and result in ["pass", "fail"],
       do: name == Map.fetch!(@candidate_names, candidate)

  defp target_observation?(_record, _candidate), do: false

  defp target_failures(observations) do
    for target <- @targets,
        Enum.any?(observations, &(&1["target"] == target and &1["result"] == "fail")) do
      %Reason{
        code: :target_gate_failed,
        message: "A supported target reported a failed gate.",
        source: target
      }
    end
  end

  defp missing_observations(observations) do
    missing =
      for target <- @targets,
          not Enum.any?(observations, &(&1["target"] == target)),
          do: "target observation missing: " <> target

    missing ++ [@full_gate_missing]
  end

  defp bounded_records([], _remaining), do: {:ok, []}

  defp bounded_records([head | tail], remaining) when remaining > 0 do
    case bounded_records(tail, remaining - 1) do
      {:ok, records} -> {:ok, [head | records]}
      :error -> :error
    end
  end

  defp bounded_records(_records, _remaining), do: :error

  defp requirement(code, message),
    do: %Reason{code: code, message: message, source: "TUI interaction contract 16.6"}
end
