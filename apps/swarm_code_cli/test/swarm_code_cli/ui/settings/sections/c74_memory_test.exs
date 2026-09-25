defmodule SwarmCodeCLI.UI.Settings.Sections.C74MemoryTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.Sections.Memory
  import SwarmCodeCLI.Test.C74U2Ctx

  defp row(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id}: #{inspect(Enum.map(rows, & &1.id))}")

  defp memory_ctx(project, opts \\ []) do
    state = Keyword.get(opts, :state, I.seed())

    {:ok, page} =
      I.query(state, %{
        "view" => "records",
        "kind" => "memory_files",
        "options" => %{"project_id" => project}
      })

    files =
      for ref <- Keyword.get(opts, :read, []), into: %{} do
        {:ok, f} = I.query(state, %{"view" => "file", "id" => ref})
        {ref, f["file"]}
      end

    c = ctx(state, kinds: [], files: files, layer: Keyword.get(opts, :layer, []))

    put_in(c, [:data, :records, {"memory_files", %{"project_id" => project}}], %{
      items: page["items"],
      total: page["total"],
      loaded_at: 0
    })
  end

  defp pmem(p), do: "memory_project:project:#{p}:MEMORY"
  defp instr(p), do: "instructions:project:#{p}:AGENTS"

  test "three file rows: memories with lines and size, the winning instructions file with its facts" do
    a = I.ids().ailogic
    rows = Memory.rows(memory_ctx(a))
    mem = row(rows, "file:#{pmem(a)}")
    assert mem.label == "This project's memory"
    assert text(mem.value) =~ "42 lines"
    assert text(row(rows, "file:memory_global:global:-:MEMORY").value) == "empty"

    agents = row(rows, "file:#{instr(a)}")
    assert agents.label == "AGENTS.md"
    assert Enum.any?(agents.lines, &(text(&1) =~ "3 levels below (AGENTS.override.md first"))
    refute Enum.any?(rows, &(&1.id == "link:approvals.trusted"))
  end

  test "an untrusted project's instructions row warns and links to Approvals & trust" do
    n = I.ids().notes
    rows = Memory.rows(memory_ctx(n))
    claude = row(rows, "file:#{instr(n)}")
    assert claude.label == "CLAUDE.md"
    assert :attention in claude.marks
    assert Enum.any?(claude.lines, &(text(&1) =~ "! not read until you trust"))

    assert [{:section, :approvals}] =
             Memory.act(memory_ctx(n), row(rows, "link:approvals.trusted"), :open_row)
  end

  test "save carries the fingerprint as read; the fake accepts it, then a stale one conflicts" do
    a = I.ids().ailogic
    c = memory_ctx(a, read: [pmem(a)])
    mem = row(Memory.rows(c), "file:#{pmem(a)}")
    assert [{:edit, _}] = Memory.act(c, mem, :open_row)

    [{:command, "file.save", target, attrs, opts}] = Memory.commit(c, mem, "- one fact\n")
    fp = opts.expected["fingerprint"]
    assert fp == I.fingerprint(%{content: Enum.map_join(1..42, "", &"- fact #{&1}\n")})

    cmd = %{
      "action" => "file.save",
      "target" => target,
      "attributes" => attrs,
      "expected" => opts.expected
    }

    {{:ok, %{"status" => "accepted"}}, state} = I.command(I.seed(), cmd)
    {{:ok, %{"status" => "conflict"} = r}, _} = I.command(state, cmd)
    refute inspect(r) =~ "one fact"
  end

  test "conflict words after an external change; s saves over, e edits again, Esc keeps theirs" do
    a = I.ids().ailogic
    ref = pmem(a)
    fresh = %{"sha256" => "abc", "size" => 3}

    c =
      memory_ctx(a,
        read: [ref],
        layer: [file_conflicts: %{ref => %{"mine" => "- mine\n", "fingerprint" => fresh}}]
      )

    mem = row(Memory.rows(c), "file:#{ref}")

    assert Enum.any?(
             mem.lines,
             &(text(&1) ==
                 "! The file changed while you edited. s save yours over it · e edit again · Esc keep the file's version")
           )

    assert [
             {:command, "file.save", %{"ref" => ^ref}, %{"content" => "- mine\n"},
              %{expected: %{"fingerprint" => ^fresh}}}
           ] =
             Memory.act(c, mem, :save)

    assert [{:external_edit, %{content: "- mine\n", ref: ^ref}}] = Memory.act(c, mem, :external)

    assert [{:conflict_discard, {:file, ^ref}}, {:load, {:file, ^ref}}] =
             Memory.act(c, mem, :escape)
  end

  test "Enter on a missing AGENTS.md creates it; C clears a memory after asking" do
    state = I.seed()
    p = "99999999-9999-4999-8999-999999999999"
    c = memory_ctx(p, state: state)
    rows = Memory.rows(c)
    missing = row(rows, "file:#{instr(p)}")
    assert text(missing.value) == "no file yet · Enter creates it"

    [{:command, "file.save", %{"ref" => ref}, %{"content" => content}, opts}] =
      Memory.act(c, missing, :open_row)

    assert ref == instr(p) and content =~ "# AGENTS.md"
    assert opts.expected == %{"fingerprint" => %{"missing" => true}}

    a = I.ids().ailogic
    c = memory_ctx(a)
    mem = row(Memory.rows(c), "file:#{pmem(a)}")

    [{:confirm, confirm, then: [{:command, "file.clear", %{"ref" => _}, %{}, _}]}] =
      Memory.act(c, mem, :delete)

    assert Map.get(confirm, :danger) == "Clear 42 lines"
  end
end
