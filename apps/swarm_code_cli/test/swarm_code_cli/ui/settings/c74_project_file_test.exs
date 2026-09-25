defmodule SwarmCodeCLI.UI.Settings.C74ProjectFileTest do
  @moduledoc "cli74 U3-8: the Project file page (§2.11, sketch §4.15, D14, D15)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.Settings.{Confirm, Nav, Page, Picker, Sections}
  alias SwarmCodeCLI.UI.Settings.Sections.ProjectFile

  @path "~/dev/ailogic/.swarm_code/config.json"

  defp config(extra) do
    Map.merge(
      %{
        "path" => @path,
        "parse" => "ok",
        "fingerprint" => "fp1",
        "trusted" => true,
        "top_level" => %{"effort" => "high"},
        "denied" => [],
        "hooks" => %{
          "post_tool_use" => [
            %{
              "index" => 0,
              "command" => "mix format",
              "matcher" => "^edit_file$",
              "timeout_ms" => 10_000
            }
          ]
        },
        "ignored_entries" => [
          %{
            "path" => "hooks.post_edit",
            "reason" => "unknown event post_edit",
            "severity" => "error"
          },
          %{
            "path" => "profiles.fast.mode",
            "reason" => "not a profile key",
            "severity" => "warning"
          }
        ],
        "profiles" => %{"fast" => %{"effort" => "low"}}
      },
      extra
    )
  end

  defp ctx(extra \\ %{}, files \\ %{}) do
    {state, _fake} = opened(:project_file)
    ctx = Nav.ctx(state)
    id = project_id(ctx)
    data = %{ctx.data | record: %{{"project_config", id} => config(extra)}, files: files}
    %{ctx | data: data}
  end

  defp project_id(ctx) do
    {:record, "project_config", id} =
      Enum.find(Sections.loads(:project_file, ctx), &match?({:record, _, _}, &1))

    id
  end

  defp page(ctx), do: ctx |> then(&Sections.rows(:project_file, &1))

  defp text(rows), do: Enum.map_join(rows, "\n", &all_words/1)

  test "the sketch: header, ignored keys, hooks table, ignored entries, profiles" do
    ctx = ctx()
    rows = page(ctx)
    text = text(rows)

    assert ProjectFile.title(ctx) == "Project file · " <> @path
    assert %{label: @path} = header = hd(rows)
    assert words(header) == "✓ read"
    assert words(header.tag) == "e edit the whole file"

    assert text =~ "keys SwarmCode ignores"
    assert text =~ "effort high · SwarmCode ignores this key x remove"
    assert text =~ "run only in trusted projects · ailogic is trusted"
    assert text =~ "event matcher command timeout"
    assert text =~ "post_tool_use ^edit_file$ mix format 10 s"
    assert text =~ "✗ hooks.post_edit · unknown event post_edit x remove"
    assert text =~ "! profiles.fast.mode · not a profile key x remove"
    assert text =~ "name model effort sub-agent effort"
    assert text =~ "fast — low —"
  end

  test "the header's parse state words" do
    invalid = ctx(%{"parse" => "invalid", "error" => "line 3, column 7"}) |> page() |> hd()
    assert words(invalid) == "✗ not valid JSON (line 3, column 7)"
    missing = ctx(%{"parse" => "missing"}) |> page() |> hd()
    assert words(missing) == "no file yet"
  end

  test "an untrusted project says hooks run only when trusted and links to Approvals" do
    ctx = ctx(%{"trusted" => false})
    rows = page(ctx)
    link = Enum.find(rows, &(&1.id == "info:untrusted"))
    assert words(link) == "Hooks run only in trusted projects. ailogic is not trusted."
    assert [{:section, :approvals}] = Sections.act(:project_file, ctx, link, :open_row)
  end

  test "x removes an ignored key and an ignored entry by structured writes" do
    ctx = ctx()
    rows = page(ctx)
    id = project_id(ctx)

    key = Enum.find(rows, &(&1.id == "pf:effort"))

    assert [
             {:command, "project_config.remove_key", %{"key" => "effort", "project_id" => ^id},
              %{}, %{expected: %{"fingerprint" => "fp1"}}}
           ] = Sections.act(:project_file, ctx, key, :delete)

    entry = Enum.find(rows, &(&1.id == "ignored:hooks.post_edit"))

    assert [{:command, "project_config.remove_entry", %{"path" => "hooks.post_edit"}, %{}, _}] =
             Sections.act(:project_file, ctx, entry, :delete)
  end

  test "a new hook in a trusted project asks before it is saved; untrusted it does not" do
    ctx = ctx()
    row = Enum.find(page(ctx), &(&1.id == "hook:post_tool_use:0"))

    assert [{:picker, %Picker{on_pick: {:section, :project_file, :new_hook}}}] =
             Sections.act(:project_file, ctx, row, :add)

    assert [{:open, %Page{record: {"hook", "new:pre_tool_use"} = record}}] =
             Sections.picked(:project_file, ctx, :new_hook, "pre_tool_use")

    {"hook", hook_id} = record
    fields = Sections.record_rows(:project_file, ctx, "hook", hook_id)
    command = Enum.find(fields, &(&1.id == "fld:hook:new:pre_tool_use:command"))

    assert [{:confirm, %Confirm{title: "Run this on your machine?", lines: [line]}, then: then}] =
             Sections.commit(:project_file, ctx, command, "mix credo")

    assert line == "In ailogic, whenever pre_tool_use: mix credo"

    assert [
             {:command, "project_config.put_hook", %{"event" => "pre_tool_use", "index" => nil},
              %{"command" => "mix credo", "confirmed" => true}, _}
           ] = then

    untrusted = ctx(%{"trusted" => false})

    assert [{:command, "project_config.put_hook", _, attrs, _}] =
             Sections.commit(:project_file, untrusted, command, "mix credo")

    refute Map.has_key?(attrs, "confirmed")
  end

  test "changing an existing hook's timeout does not ask; a bad matcher is refused" do
    ctx = ctx()
    fields = Sections.record_rows(:project_file, ctx, "hook", "post_tool_use:0")
    timeout = Enum.find(fields, &(&1.id == "fld:hook:post_tool_use:0:timeout_ms"))

    assert [
             {:command, "project_config.put_hook", %{"event" => "post_tool_use", "index" => 0},
              %{"timeout_ms" => 5_000, "command" => "mix format"}, _}
           ] = Sections.commit(:project_file, ctx, timeout, 5_000)

    matcher = Enum.find(fields, &(&1.id == "fld:hook:post_tool_use:0:matcher"))

    assert [{:toast, "not a valid regular expression: " <> _, :error}] =
             Sections.commit(:project_file, ctx, matcher, "*.ex")
  end

  test "e edits the whole file; hooks it adds show the D14 dialog and re-send confirmed" do
    ref = ProjectFile.ref(project_id(ctx()))
    files = %{ref => %{fields: %{"fingerprint" => "fp1"}, content: "{}\n"}}
    ctx = ctx(%{}, files)
    header = hd(page(ctx))

    assert [{:external_edit, %{ref: ^ref, content: "{}\n", suffix: ".json"}}] =
             Sections.act(:project_file, ctx, header, :edit_external)

    edited = ~s({"hooks": {"post_tool_use": [{"command": "rm -rf tmp"}]}}\n)

    assert {:confirm, %Confirm{title: "Run these on your machine?", lines: lines}, then: then} =
             ProjectFile.confirm_external(
               ctx,
               %{content: edited, fingerprint: "fp1"},
               ["post_tool_use: rm -rf tmp"]
             )

    assert lines == ["In ailogic, the file now runs:", "  post_tool_use · rm -rf tmp"]

    assert [
             {:command, "file.save", %{"ref" => ^ref},
              %{"content" => ^edited, "confirmed_hooks" => true},
              %{expected: %{"fingerprint" => "fp1"}}}
           ] = then
  end
end
