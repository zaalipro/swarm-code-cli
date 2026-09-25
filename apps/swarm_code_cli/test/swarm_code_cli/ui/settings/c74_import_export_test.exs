defmodule SwarmCodeCLI.UI.Settings.C74ImportExportTest do
  @moduledoc "cli74 U3-13: Import & export (§2.22, sketch §4.15 Import preview)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.Settings.{Confirm, Nav, Page, Sections}
  alias SwarmCodeCLI.UI.Settings.Sections.ImportExport

  @path "~/swarmcode-settings-2026-09-20.json"

  defp base do
    {state, _fake} = opened(:import_export)
    Nav.ctx(state)
  end

  defp preview_rows do
    [
      %{
        "id" => "1",
        "scope" => "global",
        "key_or_record" => "limits.max_concurrent_agents",
        "now" => 6,
        "after" => 8,
        "status" => "change"
      },
      %{
        "id" => "2",
        "scope" => "terminal",
        "key_or_record" => "terminal.panel",
        "now" => "compact",
        "after" => "full",
        "status" => "change"
      },
      %{
        "id" => "3",
        "scope" => "global",
        "key_or_record" => "research.max_live",
        "now" => 12,
        "after" => 12,
        "status" => "same"
      },
      %{
        "id" => "4",
        "scope" => "desktop",
        "key_or_record" => "desktop.theme",
        "now" => "carbon",
        "after" => "nord",
        "status" => "invalid",
        "message" => "is invalid · not applied"
      }
    ]
  end

  defp import_ctx(rows \\ preview_rows(), ticks \\ nil) do
    ctx = base()

    view = %{
      summary: %{"values" => 71, "providers" => 3, "mcp_servers" => 1},
      pages: %{nil => rows}
    }

    data = %{ctx.data | task_views: %{"t1" => view}}
    sub = {:import, %{path: @path, task_id: "t1", ticks: ticks, cursor: nil}}
    %{ctx | data: data, page: %Page{section: :import_export, sub: sub}}
  end

  defp import_rows(ctx), do: Sections.sub_rows(:import_export, ctx, ctx.page.sub)
  defp find(rows, id), do: Enum.find(rows, &(&1.id == id))

  test "Export opens its page with today's file and every part ticked; Export sends the task" do
    ctx = base()
    export = Enum.find(Sections.rows(:import_export, ctx), &(&1.key == "transfer.export"))

    assert [{:open, %Page{sub: {:export, state}}}] =
             Sections.act(:import_export, ctx, export, :open_row)

    assert state.path =~ ~r/\A~\/swarmcode-settings-\d{4}-\d{2}-\d{2}\.json\z/
    assert "terminal" in state.scopes
    refute state.plain

    ctx = %{
      ctx
      | prefs: %{"panel" => "compact"},
        page: %Page{section: :import_export, sub: {:export, state}}
    }

    rows = Sections.sub_rows(:import_export, ctx, {:export, state})
    assert Enum.any?(rows, &(&1.label == "what goes in · never secrets"))

    scope = find(rows, "exp:scope:pricing")

    assert [:back, {:open, %Page{sub: {:export, off}}}] =
             Sections.act(:import_export, ctx, scope, :toggle)

    refute "pricing" in off.scopes

    go = find(rows, "exp:go")

    assert [{:task, "export", %{"path" => path}, attrs}] =
             Sections.act(:import_export, ctx, go, :open_row)

    assert path == state.path
    assert attrs["terminal"] == %{"panel" => "compact"}
    assert attrs["mcp_plain_values"] == false
  end

  test "Import reads the typed file with import.preview" do
    ctx = base()
    import = Enum.find(Sections.rows(:import_export, ctx), &(&1.key == "transfer.import"))

    assert [{:open, %Page{sub: {:import, state}} = page}] =
             Sections.act(:import_export, ctx, import, :open_row)

    ctx = %{ctx | page: page}

    path_row =
      ctx |> then(&Sections.sub_rows(:import_export, &1, {:import, state})) |> find("imp:path")

    assert [{:task, "import.preview", %{"path" => @path}, %{}} | _] =
             Sections.commit(:import_export, ctx, path_row, "  " <> @path <> " ")

    assert [{:toast, _, :warning}] = Sections.commit(:import_export, ctx, path_row, " ")
  end

  test "the preview (sketch): key · now · after with ticks, same and invalid rows" do
    rows = import_rows(import_ctx())
    text = Enum.map_join(rows, "\n", &all_words/1)

    assert text =~ "Import · #{@path} · 71 values, 3 providers, 1 MCP server"
    assert text =~ "[✓] limits.max_concurrent_agents 6 8"
    assert text =~ "[✓] terminal.panel compact full"
    assert text =~ "research.max_live 12 12   same"
    assert text =~ "✗ desktop.theme carbon nord   is invalid · not applied"
    assert %{label: "Apply 2 changes"} = find(rows, "imp:apply")
  end

  test "Space unticks; Enter applies the ticked rows and writes the terminal's to cli.json" do
    ctx = import_ctx()
    rows = import_rows(ctx)

    assert [:back, {:open, %Page{sub: {:import, %{ticks: ticks}}}}] =
             Sections.act(:import_export, ctx, find(rows, "imp:1"), :toggle)

    refute MapSet.member?(ticks, "1")

    apply = find(rows, "imp:apply")

    assert [
             {:task, "import.apply", nil, %{"preview_id" => "t1", "rows" => ["1", "2"]}},
             {:cli_write, %{"panel" => "full"}}
           ] = Sections.act(:import_export, ctx, apply, :open_row)

    unticked = import_ctx(preview_rows(), MapSet.new(["1"]))
    apply = unticked |> import_rows() |> find("imp:apply")

    assert [{:task, "import.apply", nil, %{"rows" => ["1"]}}] =
             Sections.act(:import_export, unticked, apply, :open_row)
  end

  test "more than 20 changes need the table as their confirmation" do
    many =
      for n <- 1..21,
          do: %{
            "id" => "#{n}",
            "scope" => "global",
            "key_or_record" => "k#{n}",
            "now" => 1,
            "after" => 2,
            "status" => "change"
          }

    ctx = import_ctx(many)
    apply = ctx |> import_rows() |> find("imp:apply")

    assert [
             {:confirm, %Confirm{title: "Apply 21 changes?"},
              then: [{:task, "import.apply", _, _}]}
           ] =
             Sections.act(:import_export, ctx, apply, :open_row)
  end

  test "Reset everything asks for the typed word and keeps unknown cli.json keys" do
    ctx = %{base() | prefs: %{"panel" => "compact", "future_key" => 1}}
    row = Enum.find(Sections.rows(:import_export, ctx), &(&1.key == "transfer.reset_everything"))

    assert [{:confirm, %Confirm{typed: "reset", undoable?: false}, then: then}] =
             Sections.act(:import_export, ctx, row, :open_row)

    assert [{:command, "values.reset", nil, %{"scope" => "all"}, _}, {:cli_write, changes}] = then
    assert changes == %{"panel" => :remove}
  end

  test "summary words" do
    assert ImportExport.summary_words(nil, "a.json") == "Import · a.json"
    assert ImportExport.summary_words(%{values: 1}, "a.json") == "Import · a.json · 1 value"
  end
end
