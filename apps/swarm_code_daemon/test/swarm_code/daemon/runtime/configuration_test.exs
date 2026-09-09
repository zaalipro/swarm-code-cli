defmodule SwarmCode.Daemon.Runtime.ConfigurationTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Runtime.{Configuration, Run}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  test "an environment-configured local provider executes a real streamed run" do
    server =
      HTTP.start(fn socket, request, _ ->
        assert request.path == "/v1/chat/completions"
        assert Jason.decode!(request.body)["model"] == "configured-model"

        HTTP.stream(socket, [
          HTTP.sse(%{
            "choices" => [
              %{"delta" => %{"content" => "Configured."}, "finish_reason" => "stop"}
            ]
          })
        ])
      end)

    on_exit(fn -> HTTP.stop(server) end)

    assert {:ok, options} =
             Configuration.from_env(
               %{
                 "SWARM_BASE_URL" => server.url <> "/v1/",
                 "SWARM_MODEL" => "configured-model",
                 "SWARM_API_KEY" => "local-fixture-key"
               },
               System.tmp_dir!()
             )

    assert options[:approval] == :ask
    refute inspect(options) =~ "local-fixture-key"

    run =
      start_supervised!({Run, options ++ [prompt: "Say configured", request_timeout_ms: 5_000]})

    assert {:ok, %{status: :completed, text: "Configured."}} = Run.await(run)
  end

  test "Anthropic selects its endpoint and key without borrowing OpenAI credentials" do
    assert {:ok, options} =
             Configuration.from_env(
               %{
                 "SWARM_PROVIDER" => "anthropic",
                 "SWARM_MODEL" => "selected-model",
                 "ANTHROPIC_API_KEY" => "anthropic-fixture",
                 "OPENAI_API_KEY" => "unrelated-fixture"
               },
               System.tmp_dir!()
             )

    assert options[:provider].kind == "anthropic"
    assert options[:provider].base_url == "https://api.anthropic.com"
    assert options[:provider].api_key == "anthropic-fixture"
  end

  test "explicit local key and approval settings override vendor defaults" do
    assert {:ok, options} =
             Configuration.from_env(
               %{
                 "SWARM_BASE_URL" => "http://localhost:8080/v1",
                 "SWARM_MODEL" => "local-model",
                 "SWARM_API_KEY" => "",
                 "OPENAI_API_KEY" => "unrelated-fixture",
                 "SWARM_APPROVAL" => "read-only",
                 "SWARM_EFFORT" => "high"
               },
               System.tmp_dir!()
             )

    assert options[:provider].api_key == ""
    assert options[:approval] == :read_only
    assert options[:effort] == "high"
  end

  test "missing model is actionable; malformed configuration never echoes credential values" do
    assert {:error, :model_required} = Configuration.from_env(%{}, System.tmp_dir!())

    for override <- [
          %{"SWARM_PROVIDER" => "unknown"},
          %{"SWARM_BASE_URL" => "https://private-key@provider.example"},
          %{"SWARM_API_KEY" => "private-key\n"},
          %{"SWARM_APPROVAL" => "yes"},
          %{"SWARM_EFFORT" => "private-key\n"},
          %{"SWARM_MODEL" => String.duplicate("x", 1_025)}
        ] do
      env = Map.merge(%{"SWARM_MODEL" => "fixture", "SWARM_API_KEY" => "private-key"}, override)
      assert {:error, reason} = Configuration.from_env(env, System.tmp_dir!())
      refute inspect(reason) =~ "private-key"
    end

    assert {:error, :invalid_project} =
             Configuration.from_env(%{"SWARM_MODEL" => "fixture"}, "/nonexistent/swarm-project")
  end

  test "vendor aliases select only the active provider and Swarm values take precedence" do
    for {kind, prefix, url} <- [
          {"openai", "OPENAI", "http://localhost:8081/v1"},
          {"anthropic", "ANTHROPIC", "http://localhost:8082"}
        ] do
      env = %{
        "SWARM_PROVIDER" => kind,
        (prefix <> "_MODEL") => "vendor-model",
        (prefix <> "_BASE_URL") => url,
        (prefix <> "_API_KEY") => "vendor-secret"
      }

      assert {:ok, options} = Configuration.from_env(env, System.tmp_dir!())
      assert options[:model] == "vendor-model"
      assert options[:provider].base_url == url
      assert options[:provider].api_key == "vendor-secret"

      assert {:ok, override} =
               Configuration.from_env(
                 Map.merge(env, %{
                   "SWARM_MODEL" => "override-model",
                   "SWARM_BASE_URL" => "http://localhost:8083",
                   "SWARM_API_KEY" => "override-secret",
                   "SWARM_APPROVAL" => "auto"
                 }),
                 System.tmp_dir!()
               )

      assert override[:model] == "override-model"
      assert override[:provider].base_url == "http://localhost:8083"
      assert override[:provider].api_key == "override-secret"
      assert override[:approval] == :auto
      refute inspect(override) =~ "override-secret"

      assert {:error, :model_required} =
               Configuration.from_env(Map.put(env, "SWARM_MODEL", ""), System.tmp_dir!())
    end

    assert {:error, :model_required} =
             Configuration.from_env(
               %{
                 "SWARM_PROVIDER" => "anthropic",
                 "OPENAI_MODEL" => "wrong-vendor"
               },
               System.tmp_dir!()
             )
  end

  test "canonical project root confines runtime tool paths without writing configuration" do
    root = Path.join(System.tmp_dir!(), "swarm-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    project = Path.join(root, "project")
    alias_path = Path.join(root, "project-alias")
    File.mkdir_p!(project)
    File.ln_s!(project, alias_path)
    File.write!(Path.join(root, "outside.txt"), "private")
    File.ln_s!(root, Path.join(project, "escape"))

    assert {:ok, options} =
             Configuration.from_env(
               %{
                 "SWARM_MODEL" => "fixture",
                 "SWARM_API_KEY" => "ephemeral-key"
               },
               alias_path
             )

    assert {:ok, canonical} = SwarmCode.Tools.Path.real_path(project)
    assert options[:project_root] == canonical

    assert {:error, _} =
             SwarmCode.Tools.Path.resolve(options[:project_root], "escape/outside.txt")

    assert File.ls!(project) == ["escape"]
    assert Enum.sort(File.ls!(root)) == ["outside.txt", "project", "project-alias"]

    File.ln_s!("cycle", Path.join(root, "cycle"))

    assert {:error, :invalid_project} =
             Configuration.from_env(%{"SWARM_MODEL" => "fixture"}, Path.join(root, "cycle"))

    assert {:error, :invalid_project} =
             Configuration.from_env(%{"SWARM_MODEL" => "fixture"}, Path.join(root, "outside.txt"))
  end

  test "invalid scalar values and terminal control bytes are rejected without exposing them" do
    root = System.tmp_dir!()

    for override <- [
          %{"SWARM_MODEL" => "bad\nmodel"},
          %{"SWARM_MODEL" => "bad\e[31mmodel"},
          %{"SWARM_MODEL" => <<255>>},
          %{"SWARM_MODEL" => ""},
          %{"SWARM_MODEL" => 123},
          %{"SWARM_EFFORT" => "high\n"},
          %{"SWARM_API_KEY" => "private\0key"},
          %{"SWARM_API_KEY" => "private\tkey"},
          %{"SWARM_API_KEY" => nil},
          %{"SWARM_BASE_URL" => "http://localhost/\tprivate"},
          %{"SWARM_BASE_URL" => ""}
        ] do
      env = Map.merge(%{"SWARM_MODEL" => "fixture"}, override)
      assert {:error, reason} = Configuration.from_env(env, root)
      assert is_atom(reason)
      refute inspect(reason) =~ "private"
    end
  end
end
