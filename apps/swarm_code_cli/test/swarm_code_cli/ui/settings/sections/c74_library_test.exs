defmodule SwarmCodeCLI.UI.Settings.Sections.C74LibraryTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.Sections.Library
  alias SwarmCodeCLI.Test.C74U2Tasks, as: T
  import SwarmCodeCLI.Test.C74U2Ctx

  defp row(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id}: #{inspect(Enum.map(rows, & &1.id))}")

  defp lib_ctx(state \\ I.seed(), opts \\ []),
    do: ctx(state, Keyword.merge([kinds: ~w(commands agent_defs skills workflows)], opts))

  @a "11111111-1111-4111-8111-111111111111"

  test "the sketch: four groups with scopes, shadowing, smoke results" do
    rows = Library.rows(lib_ctx())

    assert Enum.filter(rows, &(&1.kind == :heading)) |> Enum.map(& &1.label) ==
             ["commands", "agent definitions", "skills", "workflows"]

    deploy = row(rows, "file:command:project:#{@a}:deploy")
    assert deploy.label == "/deploy"
    assert text(deploy.value) =~ "project"
    assert text(deploy.value) =~ "build"
    assert text(deploy.value) =~ "Deploy the app to staging"

    assert text(row(rows, "file:agent:project:#{@a}:reviewer").tag) == "shadows the bundled one"
    bundled = row(rows, "file:agent:bundled:-:reviewer")
    assert text(bundled.tag) == "shadowed"
    assert bundled.state == :readonly
    assert text(row(rows, "file:agent:user:-:scout").value) =~ "claude-opus-5 · high"

    assert text(row(rows, "file:skill:project:#{@a}:html-report").value) =~
             "Build a report page · 3 files"

    assert text(row(rows, "file:workflow:user:-:nightly").value) =~ "✓ smoke ok"
    broken = row(rows, "file:workflow:project:#{@a}:broken")
    assert text(broken.value) =~ "✗ calls System.os_time/0"
    assert text(broken.tag) == "t check again"
  end

  test "smoke results per workflow come from the newest workflow.smoke task" do
    ref = "workflow:project:#{@a}:broken"
    state = %{I.seed() | smoke: Map.put(I.seed().smoke, ref, "ok")}
    {_state, id, task, trows} = T.run(state, "workflow.smoke", %{"ref" => ref}, %{"ref" => ref})
    c = lib_ctx(I.seed()) |> T.put(id, task, trows)
    assert text(row(Library.rows(c), "file:#{ref}").value) =~ "✓ smoke ok"

    assert [{:task, "workflow.smoke", %{"ref" => ^ref}, _}] =
             Library.act(c, row(Library.rows(c), "file:#{ref}"), :test)
  end

  test "bundled delete says why not; a user file asks first and sends file.delete" do
    c = lib_ctx()
    rows = Library.rows(c)

    assert [{:toast, "a built-in file cannot be deleted; make a user copy to override it", :info}] =
             Library.act(c, row(rows, "file:agent:bundled:-:reviewer"), :delete)

    [
      {:confirm, confirm,
       then: [{:command, "file.delete", %{"ref" => "agent:user:-:scout"}, %{}, _}]}
    ] =
      Library.act(c, row(rows, "file:agent:user:-:scout"), :delete)

    assert Map.get(confirm, :title) == "Delete agent scout?"
  end

  test "n asks the scope, then the name; the name rule stays on the row; create sends file.create" do
    c = lib_ctx()
    rows = Library.rows(c)
    [{:picker, picker}] = Library.act(c, row(rows, "head:commands"), :new)
    assert Map.get(picker, :on_pick) == {:section, :library, {:new, "command"}}

    [{:draft_put, "library_new", fields}, {:edit, "new:library"}] =
      Library.picked(c, {:new, "command"}, "project")

    c = put_layer(c, :drafts, %{"library_new" => %{fields: fields}})
    new = row(Library.rows(c), "new:library")

    assert [{:row_error, _, "lowercase letters, digits, ., _ or - (64 max)"}] =
             Library.commit(c, new, "Bad Name")

    [{:command, "file.create", target, %{}, opts}] = Library.commit(c, new, "ship")

    assert target == %{
             "kind" => "command",
             "scope" => "project",
             "name" => "ship",
             "project_id" => @a
           }

    assert opts.errors_to == {:draft, "library_new"}

    {{:ok, %{"status" => "accepted"}}, _} =
      I.command(I.seed(), %{"action" => "file.create", "target" => target, "attributes" => %{}})

    assert [{:toast, _, :info}] = Library.act(c, row(rows, "head:workflows"), :new)
  end

  test "a command named like the built-in /settings is marked shadowed" do
    state = I.seed()

    state =
      update_in(state.library["commands"], fn cmds ->
        cmds ++
          [
            %{
              "ref" => "command:global:-:settings",
              "project_id" => nil,
              "name" => "settings",
              "scope" => "global",
              "description" => "mine",
              "swarm" => false,
              "mode" => nil,
              "overrides_global" => false,
              "shadowed_by_builtin" => true,
              "path" => "~/.swarm_code/commands/settings.md"
            }
          ]
      end)

    rows = Library.rows(lib_ctx(state))
    s = row(rows, "file:command:global:-:settings")

    assert Enum.any?(
             s.lines,
             &(text(&1) == "! shadowed by the built-in /settings · rename the file to use it")
           )
  end

  test "o opens the folder, y copies the path, Enter opens the file in the editor" do
    ref = "agent:user:-:scout"
    {:ok, %{"file" => f}} = I.query(I.seed(), %{"view" => "file", "id" => ref})
    c = lib_ctx(I.seed(), files: %{ref => f})
    scout = row(Library.rows(c), "file:#{ref}")
    assert [{:open_folder, "~/.swarm_code/agents"}] = Library.act(c, scout, :open_related)
    assert [{:copy, "~/.swarm_code/agents/scout.md"}, _] = Library.act(c, scout, :copy)

    assert [{:external_edit, %{ref: ^ref, suffix: ".md", read_only: false}}] =
             Library.act(c, scout, :open_row)
  end
end
