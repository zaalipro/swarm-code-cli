defmodule SwarmCode.Daemon.Service.Settings.C74MCPImportTest do
  @moduledoc "pass 74 S2-8: importing MCP servers from a .mcp.json (§3.5.4, §2.7)."
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias SwarmCode.Daemon.Service.Settings.MCPImport
  alias SwarmCode.Domain.MCP
  alias SwarmCode.Domain.MCP.Server
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Test.C74S2

  @canary "sk-canary-7Q2X-DO-NOT-SHOW"
  @linear_key "lin_api_0000000000000000w1x2"
  @unset "C74_IMPORT_UNSET_#{System.unique_integer([:positive])}"

  setup do
    fx = C74S2.repo!("c74-mcp-import")
    data = C74S2.appendix_a!(fx)

    on_exit(fn ->
      for server <- [data.github, data.fs, data.docs], do: MCP.stop_client(server.id)
    end)

    mcp_json = %{
      "mcpServers" => %{
        "github" => %{
          "command" => "github-mcp-server",
          "args" => ["stdio"],
          "env" => %{
            "GITHUB_PERSONAL_ACCESS_TOKEN" => "${GITHUB_TOKEN}",
            "GITHUB_TOOLSETS" => "repos"
          }
        },
        "linear" => %{
          "type" => "http",
          "url" => "https://mcp.linear.test/mcp",
          "headers" => %{"Authorization" => "Bearer " <> @linear_key}
        },
        "home" => %{
          "command" => "home-mcp",
          "env" => %{"ROOT" => "$HOME", "SECRET_TOKEN" => "${#{@unset}}", "PLAIN" => "$NOT A VAR"}
        },
        "old" => %{"type" => "sse", "url" => "https://old.test/sse"}
      }
    }

    File.write!(Path.join(data.ailogic.root_path, ".mcp.json"), Jason.encode!(mcp_json))
    Map.merge(data, %{fx: fx, ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp read!(c, path \\ nil) do
    {:task, spec, result} =
      MCPImport.command(C74S2.command("mcp.import.read", attributes: %{"path" => path}), c.ctx)

    assert result.status == :accepted and spec.holds_secrets? and spec.timeout_ms == 10_000
    C74S2.run_task(spec)
  end

  defp apply!(c, result, attrs, secrets \\ []) do
    ctx = %{
      c.ctx
      | task_results: %{
          {"mcp.import.read", "import"} => C74S2.task_entry("imp-1", "done", result)
        }
    }

    MCPImport.command(
      C74S2.command("mcp.import.apply",
        attributes: Map.put(attrs, "import_id", "imp-1"),
        secrets: secrets
      ),
      ctx
    )
  end

  defp rows(result), do: Map.new(result["rows"], &{&1["name"], &1})

  describe "mcp.import.read" do
    test "drafts from the project's .mcp.json: masked, variables, conflicts, SSE", c do
      {:ok, result} = read!(c)
      assert result["count"] == 4 and result["conflicts"] == 1 and result["unsupported"] == 1
      rows = rows(result)
      shown = [result["rows"], Map.drop(result, ["rows", "drafts"])]
      refute inspect(shown) =~ @linear_key

      for row <- result["rows"],
          do: C74S2.declared!(%{"kind" => "mcp_import_draft", "fields" => row})

      assert rows["github"]["conflict"] and rows["github"]["transport"] == "stdio"

      assert rows["github"]["variables"] == [
               %{
                 "map" => "env",
                 "name" => "GITHUB_PERSONAL_ACCESS_TOKEN",
                 "ref" => "GITHUB_TOKEN",
                 "in_shell" => System.get_env("GITHUB_TOKEN") != nil
               }
             ]

      assert [%{"name" => "Authorization", "secret" => true, "value" => nil, "hint" => "w1x2"}] =
               rows["linear"]["headers"]

      assert rows["linear"]["transport"] == "http" and not rows["linear"]["conflict"]

      assert Enum.map(rows["home"]["variables"], &{&1["name"], &1["ref"], &1["in_shell"]}) == [
               {"ROOT", "HOME", true},
               {"SECRET_TOKEN", @unset, false}
             ]

      assert rows["old"]["unsupported"]

      assert rows["old"]["message"] ==
               "SSE servers are not supported; use the server's streamable http URL"
    end

    test "a typed path must be inside the home folder, at most 1 MiB, and JSON", c do
      outside = Path.join(c.fx.dir, "outside.json")
      File.write!(outside, ~s({"mcpServers": {}}))

      assert {:error, %{message: "only files inside your home folder can be read"}} =
               MCPImport.command(
                 C74S2.command("mcp.import.read", attributes: %{"path" => outside}),
                 c.ctx
               )

      # a symlink inside home that points outside is refused too
      link = Path.join(c.fx.home, "link.json")
      File.ln_s!(outside, link)

      assert {:error, %{message: "only files inside your home folder can be read"}} =
               MCPImport.command(
                 C74S2.command("mcp.import.read", attributes: %{"path" => "~/link.json"}),
                 c.ctx
               )

      File.write!(Path.join(c.fx.home, "big.json"), String.duplicate(" ", 1_048_577))
      assert {:error, "~/big.json is over 1 MiB"} = read!(c, "~/big.json")

      File.write!(Path.join(c.fx.home, "bad.json"), "{\n  \"mcpServers\": [,]\n}")
      assert {:error, "not valid JSON: line 2, column 18"} = read!(c, "~/bad.json")

      File.write!(Path.join(c.fx.home, "none.json"), ~s({"servers": {}}))
      assert {:error, "no \"mcpServers\" object in that file"} = read!(c, "~/none.json")
      assert {:error, "~/missing.json does not exist"} = read!(c, "~/missing.json")

      File.write!(Path.join(c.fx.home, "ok.json"), ~s({"mcpServers": {"x": {"command": "x"}}}))
      assert {:ok, %{"count" => 1, "path" => "~/ok.json"}} = read!(c, "~/ok.json")
    end
  end

  describe "mcp.import.apply" do
    test "shell, paste and literal fill the references; secrets are stored, never answered", c do
      {:ok, read} = read!(c)

      result =
        apply!(
          c,
          read,
          %{
            "names" => ["github", "linear", "home"],
            "rename" => %{"github" => "github-2"},
            "project_id" => c.ailogic.id,
            "values" => %{
              "github" => %{"env.GITHUB_PERSONAL_ACCESS_TOKEN" => "paste"},
              "home" => %{"env.ROOT" => "shell", "env.SECRET_TOKEN" => "literal"}
            }
          },
          [%{slot: "import:github:env:GITHUB_PERSONAL_ACCESS_TOKEN", value: @canary}]
        )

      assert {:ok, %{status: :accepted, message: "3 servers added"} = answer} = result
      refute inspect(answer) =~ @canary
      refute inspect(answer) =~ @linear_key

      github = Repo.get_by!(Server, name: "github-2")

      assert github.env == %{
               "GITHUB_PERSONAL_ACCESS_TOKEN" => @canary,
               "GITHUB_TOOLSETS" => "repos"
             }

      assert github.project_id == c.ailogic.id

      home = Repo.get_by!(Server, name: "home")
      assert home.env["ROOT"] == System.get_env("HOME")
      assert home.env["SECRET_TOKEN"] == "${#{@unset}}"
      assert home.env["PLAIN"] == "$NOT A VAR"

      linear = Repo.get_by!(Server, name: "linear")
      assert linear.headers == %{"Authorization" => "Bearer " <> @linear_key}

      for name <- ~w(github-2 home linear),
          do: MCP.stop_client(Repo.get_by!(Server, name: name).id)
    end

    test "per-name refusals: SSE, an unset shell variable, a missing paste, a conflict", c do
      {:ok, read} = read!(c)

      {:ok, result} =
        apply!(c, read, %{
          "names" => ["old", "home", "github", "linear", "nope"],
          "values" => %{
            "home" => %{"env.ROOT" => "shell", "env.SECRET_TOKEN" => "shell"},
            "github" => %{"env.GITHUB_PERSONAL_ACCESS_TOKEN" => "paste"}
          }
        })

      by = Map.new(result.results, &{&1.target, &1})
      assert by["old"].status == :rejected

      assert by["old"].message ==
               "SSE servers are not supported; use the server's streamable http URL"

      assert by["home"].message == "#{@unset} is not set in this shell"
      assert by["github"].message == "paste GITHUB_PERSONAL_ACCESS_TOKEN"
      assert by["linear"].status == :accepted
      assert by["nope"].message == "nope is not in that file"
      assert result.status == :rejected
      assert result.message == "1 server added · 4 not added"
      refute Repo.get_by(Server, name: "home")
      MCP.stop_client(Repo.get_by!(Server, name: "linear").id)

      {:ok, conflict} =
        apply!(c, read, %{
          "names" => ["github"],
          "values" => %{"github" => %{"env.GITHUB_PERSONAL_ACCESS_TOKEN" => "literal"}}
        })

      assert [%{status: :rejected, message: "name " <> _}] = conflict.results
    end

    test "an expired import id is not found, with words", c do
      assert {:error, %{code: :not_found, message: message}} =
               MCPImport.command(
                 C74S2.command("mcp.import.apply",
                   attributes: %{"import_id" => "gone", "names" => ["github"]}
                 ),
                 c.ctx
               )

      assert message =~ "expired"
    end
  end
end
