defmodule SwarmCodeCLI.UI.Renderer.DecisionTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Renderer.Decision

  @candidates [:ex_ratatui_013, :ratatui_port, :pure_elixir]
  @targets [
    "macos-arm64",
    "macos-x86_64",
    "ubuntu-22.04-arm64",
    "ubuntu-22.04-x86_64"
  ]

  test "the committed source record rejects the exact version with all four verified vetoes" do
    path =
      Path.expand(
        "../../../../../../docs/evidence/tui-renderer/static-exratatui-013.json",
        __DIR__
      )

    assert File.stat!(path).size <= 32_768
    record = path |> File.read!() |> Jason.decode!()
    assert {:reject, :ex_ratatui_013, reasons} = Decision.evaluate(:ex_ratatui_013, [record])

    assert Enum.map(reasons, & &1.code) == [
             :unbounded_native_paste,
             :narrow_only_width,
             :no_public_no_alt,
             :arm64_jammy_abi
           ]

    assert record["observed_at"] == "2026-09-06T08:32:04Z"
  end

  test "locked source veto rejects before any native observation exists" do
    assert {:reject, :ex_ratatui_013, reasons} =
             Decision.evaluate(:ex_ratatui_013, [static_record()])

    assert Enum.map(reasons, & &1.code) == [
             :unbounded_native_paste,
             :narrow_only_width,
             :no_public_no_alt,
             :arm64_jammy_abi
           ]

    assert Enum.all?(reasons, &(is_binary(&1.source) and is_binary(&1.message)))
  end

  test "known static veto cannot be hidden by passes, malformed observations or order" do
    record = static_record()

    assert {:reject, :ex_ratatui_013, expected} =
             Decision.evaluate(:ex_ratatui_013, [record])

    records = [nil, %{"result" => "adopt"}, record | observations(:ex_ratatui_013)]
    assert {:reject, :ex_ratatui_013, ^expected} = Decision.evaluate(:ex_ratatui_013, records)

    assert {:reject, :ex_ratatui_013, ^expected} =
             Decision.evaluate(:ex_ratatui_013, Enum.reverse(records))
  end

  test "each static veto is independently sufficient and duplicates do not multiply reasons" do
    for veto <- static_record()["vetoes"] do
      record = Map.put(static_record(), "vetoes", [veto])

      assert {:reject, :ex_ratatui_013, [reason]} =
               Decision.evaluate(:ex_ratatui_013, [record, record])

      assert Atom.to_string(reason.code) == veto["code"]
    end
  end

  test "rejection offers separately gated candidates without choosing a renderer" do
    rejection = Decision.evaluate(:ex_ratatui_013, [static_record()])

    assert [
             {:candidate, :ratatui_port, port_reasons},
             {:candidate, :pure_elixir, elixir_reasons}
           ] = Decision.next_candidates(rejection)

    assert Enum.map(port_reasons, & &1.code) == [
             :separate_plan_required,
             :declared_width_paint_plan_required,
             :guarded_port_required,
             :bounded_parser_required,
             :four_target_evidence_required
           ]

    assert Enum.map(elixir_reasons, & &1.code) == [
             :separate_plan_required,
             :exact_cell_renderer_required,
             :bounded_parser_required,
             :four_target_evidence_required
           ]

    assert Decision.next_candidates({:reject, :ratatui_port, []}) == []
    assert Decision.next_candidates({:incomplete, :ex_ratatui_013, []}) == []
  end

  test "one failed target rejects its candidate even when the other three pass" do
    for candidate <- @candidates do
      records = observations(candidate)
      [first | rest] = records
      records = [Map.put(first, "result", "fail") | rest]

      assert {:reject, ^candidate, [reason]} = Decision.evaluate(candidate, records)
      assert reason.code == :target_gate_failed
      assert reason.source == "macos-arm64"
    end
  end

  test "a conflicting pass does not erase a failed target" do
    [first | _] = observations(:pure_elixir)
    failed = Map.put(first, "result", "fail")

    for records <- [[first, failed], [failed, first]] do
      assert {:reject, :pure_elixir, [_]} = Decision.evaluate(:pure_elixir, records)
    end
  end

  test "missing evidence is incomplete and four pass claims are not a full gate campaign" do
    for candidate <- @candidates do
      assert {:incomplete, ^candidate, missing} = Decision.evaluate(candidate, [])
      assert Enum.all?(@targets, &(("target observation missing: " <> &1) in missing))

      assert {:incomplete, ^candidate, requirements} =
               Decision.evaluate(candidate, observations(candidate))

      assert "candidate-specific full-gate verification is not implemented" in requirements
      refute Enum.any?(requirements, &String.starts_with?(&1, "target observation missing:"))
    end
  end

  test "one candidate's static or target records neither reject nor adopt another" do
    for candidate <- [:ratatui_port, :pure_elixir] do
      foreign = [static_record() | observations(:ex_ratatui_013)]
      assert {:incomplete, ^candidate, _} = Decision.evaluate(candidate, foreign)

      failed_foreign = Enum.map(observations(:ex_ratatui_013), &Map.put(&1, "result", "fail"))
      assert {:incomplete, ^candidate, _} = Decision.evaluate(candidate, failed_foreign)
    end

    altered = Map.put(static_record(), "candidate", "ratatui_port")
    assert {:incomplete, :ratatui_port, _} = Decision.evaluate(:ratatui_port, [altered])
  end

  test "unknown candidates are rejected at the API boundary including plain and TermUI" do
    for candidate <- [:plain, :plain_session, :term_ui, :unknown, "ex_ratatui_013", nil] do
      assert_raise ArgumentError, fn -> Decision.evaluate(candidate, []) end
    end
  end

  test "malformed and unknown evidence cannot become a decision or create atoms" do
    unique_code = "unknown_renderer_code_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unique_code) end
    base = static_record()

    malformed = [
      nil,
      :pass,
      [],
      %{"candidate" => "ex_ratatui_013", "result" => "adopt"},
      Map.put(base, "schema_version", 2),
      Map.put(base, "result", "pass"),
      Map.put(base, "observed_at", "not a timestamp"),
      Map.put(base, "source_commit", String.duplicate("0", 40)),
      Map.put(base, "vetoes", []),
      Map.put(base, "vetoes", [%{"code" => unique_code, "source" => "unverified"}]),
      Map.put(base, "vetoes", [%{"code" => "unbounded_native_paste", "source" => ""}]),
      Map.put(base, "extra", true),
      Map.delete(base, "hex_outer_sha256")
    ]

    for record <- malformed do
      assert {:incomplete, :ex_ratatui_013, _} = Decision.evaluate(:ex_ratatui_013, [record])
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique_code) end

    for evidence <- [nil, %{}, :pass, [nil | :improper]] do
      assert {:incomplete, :pure_elixir, _} = Decision.evaluate(:pure_elixir, evidence)
    end
  end

  test "unknown target and malformed target records cannot supply missing observations" do
    [record | _] = observations(:ratatui_port)

    for malformed <- [
          Map.put(record, "target", "windows-x86_64"),
          Map.put(record, "result", true),
          Map.put(record, "kind", "verified_campaign"),
          Map.put(record, "verified", true),
          Map.put(record, "candidate", :ratatui_port)
        ] do
      assert {:incomplete, :ratatui_port, missing} =
               Decision.evaluate(:ratatui_port, [malformed])

      assert "target observation missing: macos-arm64" in missing
    end
  end

  test "all immutable identities must match before a static record is accepted" do
    for key <- [
          "hex_inner_sha256",
          "hex_outer_sha256",
          "tag_object",
          "source_commit",
          "ratatui_commit",
          "crossterm_commit"
        ] do
      altered = Map.put(static_record(), key, "unverified")
      assert {:incomplete, :ex_ratatui_013, _} = Decision.evaluate(:ex_ratatui_013, [altered])
    end
  end

  test "static records reject malformed veto collections and unbounded source strings" do
    [veto | _] = static_record()["vetoes"]

    for vetoes <- [
          [veto, veto],
          [veto | :improper],
          List.duplicate(veto, 5),
          [Map.put(veto, "source", String.duplicate("x", 4097))],
          [Map.put(veto, "source", " \n\t")],
          [Map.put(veto, "source", <<255>>)],
          [Map.put(veto, "extra", true)],
          [Map.put(veto, "code", :unbounded_native_paste)]
        ] do
      record = Map.put(static_record(), "vetoes", vetoes)
      assert {:incomplete, :ex_ratatui_013, _} = Decision.evaluate(:ex_ratatui_013, [record])
    end

    record =
      Map.put(static_record(), "vetoes", [Map.put(veto, "source", String.duplicate("x", 4096))])

    assert {:reject, :ex_ratatui_013, [_]} = Decision.evaluate(:ex_ratatui_013, [record])
  end

  test "the evidence collection has an explicit finite input bound" do
    [record | _] = observations(:pure_elixir)
    failed = Map.put(record, "result", "fail")

    assert {:reject, :pure_elixir, [_]} =
             Decision.evaluate(:pure_elixir, List.duplicate(failed, 64))

    assert {:incomplete, :pure_elixir, [message]} =
             Decision.evaluate(:pure_elixir, List.duplicate(failed, 65))

    assert message == "evidence must be a proper list of at most 64 records"
  end

  # This literal exercises the documented DTO; it is not a source-verification record.
  defp static_record do
    %{
      "schema_version" => 1,
      "candidate" => "ex_ratatui_013",
      "result" => "reject",
      "observed_at" => "2026-09-03T00:00:00Z",
      "hex_inner_sha256" => "5b9a488a8b895b06cef782ba47effd3a7e03a675d0f44d70277349ad70326671",
      "hex_outer_sha256" => "0448833a5de5aed13fb480f57278deefe1ca3ff62af0d32e64515f4af674c030",
      "tag_object" => "e47964edac37e776ee8c43bd53241083b0aa8813",
      "source_commit" => "aa68bfc36016d90d6b1317f1f5edc8c4a6f9d045",
      "ratatui_commit" => "e665c36cb14752a61cd777fbd06dbef8474f2add",
      "crossterm_commit" => "36d95b26a26e64b0f8c12edfe11f410a6d56a812",
      "vetoes" => [
        %{"code" => "unbounded_native_paste", "source" => "fixture: native paste allocation"},
        %{"code" => "narrow_only_width", "source" => "fixture: physical width"},
        %{"code" => "no_public_no_alt", "source" => "fixture: alternate screen initialization"},
        %{"code" => "arm64_jammy_abi", "source" => "fixture: published artifact ABI"}
      ]
    }
  end

  defp observations(candidate) do
    Enum.map(@targets, fn target ->
      %{
        "schema_version" => 1,
        "kind" => "target_observation",
        "candidate" => Atom.to_string(candidate),
        "target" => target,
        "result" => "pass"
      }
    end)
  end
end
