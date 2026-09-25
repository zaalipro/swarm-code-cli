defmodule SwarmCode.Daemon.Service.Settings.C74ProjectConfigTest do
  @moduledoc "pass 74 S2-13: a project's config.json in settings (§3.5.8, AT7–AT9)."
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings.ProjectConfig
  alias SwarmCode.Domain.Hooks
  alias SwarmCode.Test.C74S2

  setup do
    fx = C74S2.repo!("c74-project-config")
    data = C74S2.appendix_a!(fx)
    Map.merge(data, %{fx: fx, ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp config_path(project), do: Path.join([project.root_path, ".swarm_code", "config.json"])

  defp record!(project) do
    {:ok, record} = ProjectConfig.query("record", "project_config", %{"id" => project.id}, %{})
    C74S2.declared!(record)
    record["fields"]
  end

  defp run(c, action, target, attrs \\ %{}, project \\ nil) do
    project = project || c.ailogic

    ProjectConfig.command(
      C74S2.command(action,
        target: Map.put(target, "project_id", project.id),
        attributes: attrs,
        expected: %{"fingerprint" => record!(project)["fingerprint"]}
      ),
      c.ctx
    )
  end

  defp decoded(project), do: project |> config_path() |> File.read!() |> Jason.decode!()

  describe "the record" do
    test "Appendix A: top level, ignored entries, one runnable hook, unknown keys", c do
      fields = record!(c.ailogic)
      assert fields["parse"] == "ok" and fields["exists"] and fields["trusted"]
      assert fields["top_level"] == %{"effort" => "high"}
      assert fields["unknown_keys"] == ["x-custom"]
      assert fields["denied"] == []

      assert fields["ignored_entries"] == [
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
             ]

      assert [%{"command" => "mix format", "matcher" => "^edit_file$", "index" => 0}] =
               fields["hooks"]["post_tool_use"]

      assert [%{"name" => "fast", "effort" => "low"}] = fields["profiles"]

      assert [%{id: "AT8", reason: "effort, hooks.post_edit, profiles.fast.mode"} = at8] =
               ProjectConfig.attention(c.ctx)

      assert at8.title == "ailogic's project file has entries SwarmCode ignores"
    end

    test "every ignored-entry reason of §3.5.8", c do
      File.write!(config_path(c.ailogic), """
      {"hooks": {
         "pre_tool_use": [
           "echo not-a-map",
           {"matcher": "x"},
           {"command": "a", "matcher": "*.ex"},
           {"command": "b", "timeout_ms": 50000},
           {"command": "c", "timeout_ms": "10s", "output_cap": 99999}
         ],
         "session_start": {"command": "x"}
       },
       "profiles": {"bad name!": {}, "ok": 3, "fine": {"effort": "low", "mode": "auto"}},
       "tavily_api_key": "tvly-x"}
      """)

      fields = record!(c.ailogic)
      entries = Enum.map(fields["ignored_entries"], &{&1["path"], &1["reason"], &1["severity"]})

      assert entries == [
               {"hooks.pre_tool_use[0]", "not a hook", "error"},
               {"hooks.pre_tool_use[1]", "no command · dropped", "error"},
               {"hooks.pre_tool_use[2].matcher",
                ~s(matcher "*.ex" is not a regular expression · runs for every tool), "warning"},
               {"hooks.pre_tool_use[3].timeout_ms", "timeout 50000 · used as 30000", "warning"},
               {"hooks.pre_tool_use[4].timeout_ms", ~s(timeout "10s" · used as 10000), "warning"},
               {"hooks.pre_tool_use[4].output_cap", "output cap 99999 · used as 16384",
                "warning"},
               {"hooks.session_start", "not a hook", "error"},
               {"profiles.bad name!", "not a profile name · dropped", "error"},
               {"profiles.ok", "not a profile name · dropped", "error"},
               {"profiles.fine.mode", "not a profile key", "warning"}
             ]

      assert fields["denied"] == ["tavily_api_key"]
    end

    test "invalid JSON is reported with its position (AT7); writes are refused", c do
      File.write!(config_path(c.ailogic), "{\n  \"effort\": \"high\",\n  oops\n}\n")
      fields = record!(c.ailogic)
      assert fields["parse"] == "invalid"
      assert {fields["line"], fields["column"]} == {3, 3}
      assert fields["error"] == "line 3, column 3: unexpected character"

      assert [%{id: "AT7", severity: "error", reason: "line 3, column 3"}] =
               ProjectConfig.attention(c.ctx)

      {:ok, refused} = run(c, "project_config.remove_key", %{"key" => "effort"})
      assert refused.status == :rejected
      assert refused.message == "the file is not valid JSON; fix it first (e opens it)"
    end

    test "AT9: hooks in an untrusted project", c do
      File.mkdir_p!(Path.dirname(config_path(c.notes)))

      File.write!(
        config_path(c.notes),
        ~s({"hooks": {"session_start": [{"command": "echo hi"}]}})
      )

      ctx = C74S2.context(c.notes)

      assert [%{id: "AT9", title: "Hooks will not run until you trust notes"}] =
               ProjectConfig.attention(ctx)
    end
  end

  describe "structured writes" do
    test "a hook add keeps unknown keys semantically equal, asks in a trusted project", c do
      before = decoded(c.ailogic)
      attrs = %{"command" => "mix test --stale", "matcher" => "^edit", "timeout_ms" => 20_000}

      {:ok, ask} =
        run(c, "project_config.put_hook", %{"event" => "post_tool_use", "index" => nil}, attrs)

      assert ask.status == :needs_confirmation
      assert ask.confirm == %{kind: "hooks", items: ["post_tool_use: mix test --stale"]}
      assert decoded(c.ailogic) == before

      {:ok, saved} =
        run(
          c,
          "project_config.put_hook",
          %{"event" => "post_tool_use", "index" => nil},
          Map.put(attrs, "confirmed", true)
        )

      assert saved.status == :accepted
      after_write = decoded(c.ailogic)
      assert Map.delete(after_write, "hooks") == Map.delete(before, "hooks")
      assert after_write["hooks"]["post_edit"] == before["hooks"]["post_edit"]

      assert List.last(after_write["hooks"]["post_tool_use"]) ==
               %{"command" => "mix test --stale", "matcher" => "^edit", "timeout_ms" => 20_000}

      # key order survives
      text = File.read!(config_path(c.ailogic))
      assert :binary.match(text, "\"effort\"") < :binary.match(text, "\"x-custom\"")

      # editing the matcher of an existing hook does not ask again
      {:ok, edited} =
        run(c, "project_config.put_hook", %{"event" => "post_tool_use", "index" => 0}, %{
          "command" => "mix format",
          "matcher" => "^write_file$"
        })

      assert edited.status == :accepted
      assert hd(decoded(c.ailogic)["hooks"]["post_tool_use"])["matcher"] == "^write_file$"
    end

    test "hook validation with the cli words", c do
      assert {:error, %{field_errors: errors}} =
               run(c, "project_config.put_hook", %{"event" => "pre_tool_use", "index" => nil}, %{
                 "command" => " ",
                 "matcher" => "(",
                 "timeout_ms" => 0,
                 "output_cap" => 20_000
               })

      assert Enum.map(errors, & &1.target) == ~w(command matcher timeout_ms output_cap)
      assert Enum.at(errors, 0).message == "can't be blank"
      assert Enum.at(errors, 1).message =~ "not a valid regular expression: "
      assert Enum.at(errors, 2).message == "must be between 1 and 30000"
      assert Enum.at(errors, 3).message == "must be between 1 and 16384"
    end

    test "a changed file is a conflict; nothing is written", c do
      stale = record!(c.ailogic)["fingerprint"]
      File.write!(config_path(c.ailogic), ~s({"effort": "low"}))

      {:ok, conflict} =
        ProjectConfig.command(
          C74S2.command("project_config.remove_key",
            target: %{"project_id" => c.ailogic.id, "key" => "effort"},
            expected: %{"fingerprint" => stale}
          ),
          c.ctx
        )

      assert conflict.status == :conflict
      assert [%{target: "fingerprint", current: %{"sha256" => _}}] = conflict.results
      assert decoded(c.ailogic) == %{"effort" => "low"}
    end

    test "profiles: add, rename in place, validation, delete", c do
      {:ok, added} =
        run(c, "project_config.put_profile", %{"name" => nil}, %{
          "name" => "deep",
          "effort" => "high",
          "model" => "claude-opus-5"
        })

      assert added.status == :accepted

      assert decoded(c.ailogic)["profiles"]["deep"] == %{
               "effort" => "high",
               "model" => "claude-opus-5"
             }

      {:ok, renamed} =
        run(c, "project_config.put_profile", %{"name" => "fast"}, %{
          "name" => "quick",
          "effort" => "low"
        })

      assert renamed.status == :accepted
      profiles = decoded(c.ailogic)["profiles"]
      assert Map.keys(profiles) |> Enum.sort() == ["deep", "quick"]
      # the unknown key of the renamed profile survives; the order is kept
      assert profiles["quick"] == %{"mode" => "auto", "effort" => "low"}
      text = File.read!(config_path(c.ailogic))
      assert :binary.match(text, "\"quick\"") < :binary.match(text, "\"deep\"")

      assert {:error, %{field_errors: [%{target: "name", message: "already used"}]}} =
               run(c, "project_config.put_profile", %{"name" => nil}, %{"name" => "deep"})

      assert {:error, %{field_errors: [%{message: "1 to 32 letters, digits, _ or -"}]}} =
               run(c, "project_config.put_profile", %{"name" => nil}, %{"name" => "no spaces"})

      assert {:error, %{field_errors: [%{target: "effort", message: "has invalid format"}]}} =
               run(c, "project_config.put_profile", %{"name" => nil}, %{
                 "name" => "x",
                 "effort" => "Very High"
               })

      {:ok, deleted} = run(c, "project_config.delete_profile", %{"name" => "deep"})
      assert deleted.status == :accepted
      refute Map.has_key?(decoded(c.ailogic)["profiles"], "deep")
    end

    test "remove_key and remove_entry take only what is ignored", c do
      {:ok, removed} = run(c, "project_config.remove_key", %{"key" => "effort"})
      assert removed.status == :accepted
      refute Map.has_key?(decoded(c.ailogic), "effort")

      assert {:error, %{code: :invalid}} =
               run(c, "project_config.remove_key", %{"key" => "x-custom"})

      {:ok, entry} = run(c, "project_config.remove_entry", %{"path" => "profiles.fast.mode"})
      assert entry.status == :accepted
      assert decoded(c.ailogic)["profiles"]["fast"] == %{"effort" => "low"}

      {:ok, event} = run(c, "project_config.remove_entry", %{"path" => "hooks.post_edit"})
      assert event.status == :accepted
      assert Map.keys(decoded(c.ailogic)["hooks"]) == ["post_tool_use"]
      assert record!(c.ailogic)["ignored_entries"] == []
      assert decoded(c.ailogic)["x-custom"] == true

      {:ok, not_listed} =
        run(c, "project_config.remove_entry", %{"path" => "hooks.post_tool_use"})

      assert not_listed.status == :rejected
    end

    test "a missing file starts from an empty object; remove_top_level for Values", c do
      bare = C74S2.project!(c.fx.dir, "bare")

      {:ok, created} =
        run(
          c,
          "project_config.put_profile",
          %{"name" => nil},
          %{"name" => "p1", "effort" => "low"},
          bare
        )

      assert created.status == :accepted
      assert decoded(bare) == %{"profiles" => %{"p1" => %{"effort" => "low"}}}

      fp = record!(c.ailogic)["fingerprint"]
      assert ProjectConfig.read_top_level(c.ailogic) == %{"effort" => "high"}

      assert {:ok, %{fingerprint: new_fp}} =
               ProjectConfig.remove_top_level(c.ailogic, ["effort"], fp)

      assert new_fp == record!(c.ailogic)["fingerprint"]
      assert ProjectConfig.read_top_level(c.ailogic) == %{}
      assert {:conflict, _} = ProjectConfig.remove_top_level(c.ailogic, ["effort"], fp)
      assert [%{"name" => "fast"}] = ProjectConfig.profiles(c.ailogic)
    end

    test "move_hook twice within one second: the engine reads the new order", c do
      File.write!(
        config_path(c.ailogic),
        ~s({"hooks": {"session_start": [{"command": "echo A"}, {"command": "echo B"}]}})
      )

      order = fn -> Hooks.run(:session_start, %{project: c.ailogic}, c.ailogic.root_path) end
      assert {:inject, text} = order.()
      assert text =~ ~r/A.*B/s

      {:ok, _} =
        run(c, "project_config.move_hook", %{"event" => "session_start", "index" => 0}, %{
          "dir" => 1
        })

      assert {:inject, text} = order.()
      assert text =~ ~r/B.*A/s

      {:ok, _} =
        run(c, "project_config.move_hook", %{"event" => "session_start", "index" => 0}, %{
          "dir" => 1
        })

      assert {:inject, text} = order.()
      assert text =~ ~r/A.*B/s

      {:ok, edge} =
        run(c, "project_config.move_hook", %{"event" => "session_start", "index" => 1}, %{
          "dir" => 1
        })

      assert edge.status == :unchanged
    end
  end
end
