defmodule SwarmCodeCLI.UI.Settings.Sections.C74LanguageServersTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.Sections.LanguageServers, as: LS
  alias SwarmCodeCLI.Test.C74U2Tasks, as: T
  import SwarmCodeCLI.Test.C74U2Ctx

  defp row(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id}: #{inspect(Enum.map(rows, & &1.id))}")

  defp lsp_ctx(values \\ %{}) do
    values =
      Map.merge(
        default_values(),
        Map.new(values, fn {k, v} -> {k, %{key: k, value: v, state: "ok"}} end)
      )

    {state, id, task, rows} = T.run(I.seed(), "lsp.check", nil)
    ctx(state, values: values) |> T.put(id, task, rows)
  end

  test "the page loads its values and starts lsp.check" do
    assert {:auto_task, "lsp.check", nil} in LS.loads(ctx())
  end

  test "13 rows with check results, running counts, no default, off and custom" do
    rows = LS.rows(lsp_ctx(%{"lsp.erlang" => "erlang_ls", "lsp.zig" => "off"}))
    assert length(Enum.filter(rows, &(&1.kind == :setting))) == 13

    elixir = row(rows, "key:lsp.elixir")
    assert text(elixir.tag) =~ "✓ installed"
    assert Enum.any?(elixir.lines, &(text(&1) == "1 running in ailogic"))

    assert text(row(rows, "key:lsp.python").tag) =~ "✗ not installed: pyright-langserver"
    assert text(row(rows, "key:lsp.zig").tag) =~ "off"
    erlang = row(rows, "key:lsp.erlang")
    assert text(erlang.value) =~ "erlang_ls"
    assert text(erlang.tag) =~ "custom"
    assert Enum.any?(erlang.lines, &(text(&1) =~ "a path with spaces cannot be written"))

    fresh = row(LS.rows(lsp_ctx()), "key:lsp.erlang")
    assert text(fresh.value) =~ "no default: set a command"
    # cli74 F15: each word once — the tag says it, the state does not repeat it.
    assert text(fresh.tag) == "  no default"
    assert text(row(rows, "key:lsp.zig").tag) == "  off"
  end

  test "off, a custom command and back to default write lsp.<language>" do
    c = lsp_ctx()
    elixir = row(LS.rows(c), "key:lsp.elixir")

    assert [{:patch, "lsp.elixir", "off"}] = LS.act(c, elixir, :toggle)
    assert [{:patch, "lsp.elixir", "off"}] = LS.commit(c, elixir, :off)
    assert [{:patch, "lsp.elixir", "next-ls --stdio"}] = LS.commit(c, elixir, " next-ls --stdio ")
    assert [{:row_error, _, "can't be blank"}] = LS.commit(c, elixir, "  ")
    assert [{:row_error, _, "one line only"}] = LS.commit(c, elixir, "a\nb")

    assert [{:row_error, _, "should be at most 1024 character(s)"}] =
             LS.commit(c, elixir, String.duplicate("a", 1025))

    assert [] = LS.commit(c, elixir, nil)

    c = lsp_ctx(%{"lsp.elixir" => "off"})
    elixir = row(LS.rows(c), "key:lsp.elixir")
    assert [{:patch, "lsp.elixir", nil}] = LS.act(c, elixir, :toggle)
    assert [{:patch, "lsp.elixir", nil}] = LS.act(c, elixir, :reset)
    assert [{:patch, "lsp.elixir", nil}] = LS.commit(c, elixir, :default)
  end

  test "an unknown key is listed after the languages and x sends lsp.remove_key with CAS" do
    c = lsp_ctx()
    rows = LS.rows(c)
    kotlin = row(rows, "lsp:unknown:kotlin")
    assert text(kotlin.value) == "kotlin-language-server · not a known language · x remove"

    [{:command, "lsp.remove_key", %{"key" => "kotlin"} = target, %{}, opts}] =
      LS.act(c, kotlin, :delete)

    assert opts.expected == %{"value" => "kotlin-language-server"}

    {{:ok, result}, state} =
      I.command(I.seed(), %{
        "action" => "lsp.remove_key",
        "target" => target,
        "attributes" => %{},
        "expected" => opts.expected
      })

    assert result["status"] == "accepted"
    {_s, id, task, rows} = T.run(state, "lsp.check", nil)
    c = ctx(state) |> T.put(id, task, rows)
    refute Enum.any?(LS.rows(c), &(&1.id == "lsp:unknown:kotlin"))
  end

  test "stop runs for the page project or every project; check restarts the task" do
    c = lsp_ctx()
    rows = LS.rows(c)

    assert [{:command, "lsp.stop", %{"all" => true}, %{}, _}] =
             LS.act(c, row(rows, "act:lsp.stop_all"), :open_row)

    assert [{:task, "lsp.check", nil, %{}}] = LS.act(c, row(rows, "act:lsp.check"), :open_row)
  end
end
