defmodule SwarmCode.Daemon.Service.Settings.C74FilesTest do
  @moduledoc "pass 74 S2-11: files in settings (§3.5.7, §3.4.5 refs)."
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings.Files
  alias SwarmCode.Test.C74S2

  setup do
    fx = C74S2.repo!("c74-files")
    data = C74S2.appendix_a!(fx)
    Map.merge(data, %{fx: fx, ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp view(c, ref), do: Files.query("file", nil, %{"id" => ref}, c.ctx)

  defp fields!(c, ref) do
    {:ok, %{"file" => record}} = view(c, ref)
    C74S2.declared!(record)
    record["fields"]
  end

  defp save(c, ref, content, fingerprint, attrs \\ %{}) do
    Files.command(
      C74S2.command("file.save",
        target: %{"ref" => ref},
        attributes: Map.put(attrs, "content", content),
        expected: %{"fingerprint" => fingerprint}
      ),
      c.ctx
    )
  end

  defp memory(c), do: "memory_project:project:#{c.ailogic.id}:MEMORY"

  describe "refs" do
    test "path traversal names and other forms are not found", c do
      pid = c.ailogic.id

      for ref <- [
            "command:global:-:../review",
            "command:global:-:..",
            "command:global:-:.hidden",
            "agent:user:-:../../etc/passwd",
            "skill:project:#{pid}:../../x",
            "workflow:user:-:Bad Name",
            "memory_project:project:not-a-uuid:MEMORY",
            "memory_project:project:#{Ecto.UUID.generate()}:MEMORY",
            "memory_project:global:-:MEMORY",
            "memory_global:global:-:NOTES",
            "instructions:project:#{pid}:README",
            "passwd:global:-:x",
            "command:global:-:review:extra",
            "command:global:-:" <> String.duplicate("a", 600),
            nil
          ] do
        assert {:error, %{code: :not_found}} = view(c, ref), "#{inspect(ref)} was resolved"
      end
    end

    test "a symlink out of its tier root reads as not found", c do
      outside = Path.join(c.fx.dir, "secret.md")
      File.write!(outside, "outside")
      commands = Path.join([c.ailogic.root_path, ".swarm_code", "commands"])
      File.ln_s!(outside, Path.join(commands, "evil.md"))

      assert {:error, %{code: :not_found}} =
               view(c, "command:project:#{c.ailogic.id}:evil")
    end
  end

  describe "the file view" do
    test "content, lines, fingerprint and the in-place limit", c do
      fields = fields!(c, memory(c))
      text = File.read!(Path.join([c.ailogic.root_path, ".swarm_code", "MEMORY.md"]))

      assert fields["lines"] == 42 and fields["bytes"] == byte_size(text)
      assert fields["content"] == text
      assert fields["fingerprint"] == Files.fingerprint(text)
      assert fields["editable_in_place"] and not fields["too_large"]
      assert fields["path"] =~ ".swarm_code/MEMORY.md"

      big = String.duplicate("x", 262_145)
      File.write!(Path.join([c.ailogic.root_path, "AGENTS.md"]), big)
      agents = fields!(c, "instructions:project:#{c.ailogic.id}:AGENTS")
      assert agents["too_large"] and agents["content"] == nil and not agents["editable_in_place"]
    end

    test "memory files: project, global (absent) and the instructions winner", c do
      {:ok, page} = Files.query("records", "memory_files", %{}, c.ctx)
      C74S2.declared!(page)
      [project, global, instructions] = Enum.map(page["items"], & &1["fields"])

      assert project["lines"] == 42
      assert global["exists"] == false and global["fingerprint"] == %{"missing" => true}
      assert instructions["winner"] == "AGENTS.md" and instructions["lines"] == 120
      assert instructions["trusted"] == true

      {:ok, notes} =
        Files.query(
          "records",
          "memory_files",
          %{"options" => %{"project_id" => c.notes.id}},
          c.ctx
        )

      notes_instructions = List.last(notes["items"])["fields"]
      assert notes_instructions["winner"] == "CLAUDE.md" and notes_instructions["exists"]
      assert notes_instructions["trusted"] == false
      assert List.last(notes["items"])["id"] == "instructions:project:#{c.notes.id}:CLAUDE"
    end
  end

  describe "file.save" do
    test "MEMORY.md round trip; a stale fingerprint is a conflict without content", c do
      before = fields!(c, memory(c))
      {:ok, saved} = save(c, memory(c), "- fact one\n", before["fingerprint"])
      assert saved.status == :accepted and saved.message == "MEMORY.md saved"
      assert saved.record["fields"]["parse"] == "ok"
      refute Map.has_key?(saved.record["fields"], "content")
      assert fields!(c, memory(c))["content"] == "- fact one\n"

      {:ok, stale} =
        save(c, memory(c), "- fact two #{"secretish-content"}\n", before["fingerprint"])

      assert stale.status == :conflict
      assert [%{target: "fingerprint", current: current}] = stale.results
      assert current == Files.fingerprint("- fact one\n")
      refute inspect(stale) =~ "fact one"
      refute inspect(stale) =~ "secretish-content"
      assert fields!(c, memory(c))["content"] == "- fact one\n"

      {:ok, same} = save(c, memory(c), "- fact one\n", current)
      assert same.status == :unchanged
    end

    test "the global memory file is created under the config dir", c do
      ref = "memory_global:global:-:MEMORY"
      {:ok, saved} = save(c, ref, "- global\n", %{"missing" => true})
      assert saved.status == :accepted
      assert File.read!(Path.join(c.fx.config_dir, "MEMORY.md")) == "- global\n"
    end

    test "instructions: the winner is edited; none → AGENTS.md is created", c do
      notes = "instructions:project:#{c.notes.id}:CLAUDE"
      fp = fields!(c, notes)["fingerprint"]
      {:ok, _} = save(c, notes, "# notes v2\n", fp)
      assert File.read!(Path.join(c.notes.root_path, "CLAUDE.md")) == "# notes v2\n"
      refute File.exists?(Path.join(c.notes.root_path, "AGENTS.md"))

      bare = C74S2.project!(c.fx.dir, "bare")
      ref = "instructions:project:#{bare.id}:AGENTS"
      fields = fields!(c, ref)
      assert fields["winner"] == "AGENTS.md" and fields["exists"] == false

      {:ok, created} = save(c, ref, "# bare\n", %{"missing" => true})
      assert created.status == :accepted
      assert File.read!(Path.join(bare.root_path, "AGENTS.md")) == "# bare\n"
    end

    test "a failed write leaves no temporary file", c do
      commands = Path.join([c.ailogic.root_path, ".swarm_code", "commands"])
      ref = "command:project:#{c.ailogic.id}:deploy"
      fp = fields!(c, ref)["fingerprint"]
      File.chmod!(commands, 0o500)

      try do
        assert {:error, %{code: :invalid, message: "Couldn't save " <> _}} =
                 save(c, ref, "---\ndescription: new\n---\nGo\n", fp)
      after
        File.chmod!(commands, 0o700)
      end

      assert File.ls!(commands) == ["deploy.md"]
    end

    test "a trusted project's config.json asks before a new hook command", c do
      ref = "project_config:project:#{c.ailogic.id}:config"
      fields = fields!(c, ref)
      old = fields["content"]

      new =
        old
        |> Jason.decode!()
        |> put_in(["hooks", "pre_tool_use"], [
          %{"command" => "echo checked", "matcher" => "^bash$"}
        ])
        |> Jason.encode!(pretty: true)

      {:ok, ask} = save(c, ref, new, fields["fingerprint"])
      assert ask.status == :needs_confirmation
      assert ask.confirm == %{kind: "hooks", items: ["pre_tool_use: echo checked"]}
      assert fields!(c, ref)["content"] == old

      {:ok, saved} = save(c, ref, new, fields["fingerprint"], %{"confirmed_hooks" => true})
      assert saved.status == :accepted
      assert fields!(c, ref)["content"] == new

      # an existing command is not asked again; an invalid text saves with its parse error
      {:ok, bad} = save(c, ref, "{\n  \"effort\": ", fields!(c, ref)["fingerprint"])
      assert bad.status == :accepted
      assert bad.record["fields"]["parse"] == "line 2, column 13: unexpected end"
    end

    test "an untrusted project's config.json saves without asking", c do
      ref = "project_config:project:#{c.notes.id}:config"
      text = ~s({"hooks": {"session_start": [{"command": "echo hi"}]}})
      {:ok, saved} = save(c, ref, text, %{"missing" => true})
      assert saved.status == :accepted
    end

    test "bundled files are read-only", c do
      [name | _] =
        Application.app_dir(:swarm_code_daemon, "priv/agents")
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))

      ref = "agent:bundled:-:#{Path.rootname(name)}"
      fields = fields!(c, ref)
      refute fields["editable_in_place"]
      {:ok, refused} = save(c, ref, "x", fields["fingerprint"])
      assert refused.status == :rejected
    end
  end

  describe "file.delete and file.clear" do
    test "instructions cannot be deleted; a command can; memory can be cleared", c do
      instructions = "instructions:project:#{c.ailogic.id}:AGENTS"

      {:ok, refused} =
        Files.command(
          C74S2.command("file.delete",
            target: %{"ref" => instructions},
            expected: %{"fingerprint" => fields!(c, instructions)["fingerprint"]}
          ),
          c.ctx
        )

      assert refused.status == :rejected
      assert refused.message == "edit it instead; delete the file yourself if you mean to"

      deploy = "command:project:#{c.ailogic.id}:deploy"

      {:ok, deleted} =
        Files.command(
          C74S2.command("file.delete",
            target: %{"ref" => deploy},
            expected: %{"fingerprint" => fields!(c, deploy)["fingerprint"]}
          ),
          c.ctx
        )

      assert deleted.status == :accepted

      refute File.exists?(
               Path.join([c.ailogic.root_path, ".swarm_code", "commands", "deploy.md"])
             )

      {:ok, cleared} =
        Files.command(
          C74S2.command("file.clear",
            target: %{"ref" => memory(c)},
            expected: %{"fingerprint" => fields!(c, memory(c))["fingerprint"]}
          ),
          c.ctx
        )

      assert cleared.status == :accepted
      assert fields!(c, memory(c))["content"] == ""
    end
  end
end
