defmodule SwarmCodeCLI.Cli020.E30HooksRulesTest do
  # cli020 E30 (competitors-10, competitors-11): Settings → Project file lists
  # the hooks of every event F9 adds and the permission rules (C23), read-only,
  # with the hint where they are edited.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.Settings.{Nav, Sections}

  @hint "Edit .swarm_code/config.json; ncode reads it for trusted projects only."

  defp ctx(fields) do
    {state, _fake} = opened(:project_file)
    ctx = Nav.ctx(state)

    {:record, "project_config", id} =
      Enum.find(Sections.loads(:project_file, ctx), &match?({:record, _, _}, &1))

    config =
      Map.merge(
        %{
          "path" => "~/p/.swarm_code/config.json",
          "parse" => "ok",
          "trusted" => true,
          "hooks" => %{}
        },
        fields
      )

    %{ctx | data: %{ctx.data | record: %{{"project_config", id} => config}}}
  end

  defp page(ctx), do: Sections.rows(:project_file, ctx)
  defp text(rows), do: Enum.map_join(rows, "\n", &all_words/1)

  test "hooks of the new events are rows" do
    hooks = %{
      "stop" => [%{"index" => 0, "command" => "say done"}],
      "user_prompt_submit" => [%{"index" => 0, "command" => "./check.sh"}],
      "session_end" => [%{"index" => 0, "command" => "rm -f /tmp/x"}]
    }

    rows = page(ctx(%{"hooks" => hooks}))
    ids = Enum.map(rows, & &1.id)
    assert "hook:stop:0" in ids
    assert "hook:user_prompt_submit:0" in ids
    assert "hook:session_end:0" in ids
    assert text(rows) =~ "say done"
  end

  test "the three rule lists, read-only, with the hint" do
    perms = %{"allow" => ["run mix test", "read *"], "ask" => [], "deny" => ["run rm -rf *"]}
    rows = page(ctx(%{"permissions" => perms}))
    text = text(rows)

    assert text =~ "permission rules"
    assert text =~ @hint

    for {kind, words} <- [
          {"allow", "run mix test · read *"},
          {"ask", "none"},
          {"deny", "run rm -rf *"}
        ] do
      row = Enum.find(rows, &(&1.id == "rule:" <> kind))
      assert row, kind
      assert all_words(row) =~ kind
      assert all_words(row) =~ words
      assert row.kind == :info
    end
  end

  test "no rules: the hint still says where they go" do
    rows = page(ctx(%{}))
    assert Enum.find(rows, &(&1.id == "rule:allow"))
    assert text(rows) =~ @hint
  end
end
