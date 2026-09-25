defmodule SwarmCode.Daemon.Service.Settings.C74LSPTest do
  @moduledoc "pass 74 S2-10: language servers in settings (§3.5.6, §2.8)."
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings.LSP
  alias SwarmCode.Domain.Settings
  alias SwarmCode.Test.C74S2

  setup do
    fx = C74S2.repo!("c74-lsp")
    data = C74S2.appendix_a!(fx)

    {:ok, _} =
      Settings.update(%{
        lsp_servers: %{"python" => "c74-missing-lsp --stdio", "go" => "off", "kotlin" => "kls"}
      })

    Map.merge(data, %{ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp fake_client(root, language) do
    {:ok, pid} =
      Agent.start(fn -> nil end,
        name: {:via, Registry, {SwarmCode.Domain.Registry, {:lsp, root, language}}}
      )

    ref = Process.monitor(pid)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    {pid, ref}
  end

  defp check!(c) do
    {:task, spec, result} = LSP.command(C74S2.command("lsp.check"), c.ctx)
    assert result.status == :accepted and spec.timeout_ms == 5_000 and spec.cancellable?
    {:ok, check} = C74S2.run_task(spec)
    check
  end

  test "the check: 13 languages with their state, and the unknown keys", c do
    {_pid, _ref} = fake_client(c.ailogic.root_path, "elixir")
    check = check!(c)
    rows = Map.new(check["rows"], &{&1["language"], &1})

    assert Enum.map(check["rows"], & &1["language"]) == LSP.languages()
    assert length(check["rows"]) == 13

    for row <- check["rows"],
        do: C74S2.declared!(%{"kind" => "lsp_language", "fields" => row})

    # a missing executable: `✗ not installed: c74-missing-lsp`
    assert %{
             "override" => "c74-missing-lsp --stdio",
             "effective" => "c74-missing-lsp --stdio",
             "installed" => false,
             "executable" => "c74-missing-lsp",
             "default" => "pyright-langserver --stdio"
           } = rows["python"]

    assert %{"override" => "off", "effective" => nil, "installed" => nil} = rows["go"]
    assert %{"default" => nil, "effective" => nil, "installed" => nil} = rows["erlang"]
    assert rows["cpp"]["extensions"] == ~w(.cpp .cxx .cc .hpp)
    assert rows["elixir"]["running"] == [%{"project" => "ailogic", "count" => 1}]
    assert check["unknown_keys"] == [%{"key" => "kotlin", "value" => "kls"}]

    {:task, spec, _} = LSP.command(C74S2.command("lsp.check"), c.ctx)
    refute Map.has_key?(spec.summary.(check), "rows")
  end

  test "stop: one project, or every project", c do
    {pid, ref} = fake_client(c.ailogic.root_path, "elixir")
    {other, other_ref} = fake_client(c.notes.root_path, "python")

    {:ok, result} =
      LSP.command(C74S2.command("lsp.stop", target: %{"project_id" => c.ailogic.id}), c.ctx)

    assert result.message == "1 language server stopped"
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert Process.alive?(other)

    {:ok, all} = LSP.command(C74S2.command("lsp.stop", target: %{"all" => true}), c.ctx)
    assert all.message == "1 language server stopped"
    assert_receive {:DOWN, ^other_ref, :process, ^other, _}

    {:ok, none} = LSP.command(C74S2.command("lsp.stop", target: %{"all" => true}), c.ctx)
    assert none.status == :unchanged

    assert {:error, %{code: :not_found}} =
             LSP.command(
               C74S2.command("lsp.stop", target: %{"project_id" => Ecto.UUID.generate()}),
               c.ctx
             )
  end

  test "an unknown key is removable with CAS on its value; a language is not", c do
    remove = fn key, value ->
      LSP.command(
        C74S2.command("lsp.remove_key", target: %{"key" => key}, expected: %{"value" => value}),
        c.ctx
      )
    end

    {:ok, stale} = remove.("kotlin", "old")
    assert stale.status == :conflict
    assert [%{target: "kotlin", current: "kls"}] = stale.results

    {:ok, removed} = remove.("kotlin", "kls")
    assert removed.status == :accepted and removed.message == "kotlin removed"

    assert Settings.get().lsp_servers == %{
             "python" => "c74-missing-lsp --stdio",
             "go" => "off"
           }

    {:ok, again} = remove.("kotlin", "kls")
    assert again.status == :unchanged

    assert {:error, %{message: "python is a known language"}} = remove.("python", "x")
  end
end
