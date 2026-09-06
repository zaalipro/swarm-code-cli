defmodule SwarmCode.Tools.OwnedCommandTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Tools

  setup do
    root = Path.join(System.tmp_dir!(), "owned-command-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      ctx: %{project_root: root, settings: %{command_timeout_ms: 150}},
      p: fn _, _ -> :ok end
    }
  end

  test "executes a real fixture test with combined streamed output and closed stdin", %{
    root: root,
    ctx: ctx
  } do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"

    File.write!(
      Path.join(root, "test.sh"),
      "test \"$(cat input)\" = fixed || exit 9\nprintf 'fixture passed\\n'\nprintf 'diagnostic\\n' >&2\ncat\n"
    )

    File.write!(Path.join(root, "input"), "fixed")
    owner = self()

    assert {:ok, output} =
             Tools.run("run_command", %{"command" => "sh test.sh"}, ctx, fn _, text ->
               send(owner, {:progress, text})
               :ok
             end)

    assert output =~ "exit code 0"
    assert output =~ "fixture passed"
    assert output =~ "diagnostic"
    assert_receive {:progress, _}
    File.write!(Path.join(root, "input"), "broken")

    assert {:ok, output} =
             Tools.run("run_command", %{"command" => "sh test.sh"}, ctx, fn _, _ -> :ok end)

    assert output =~ "exit code 9"
  end

  test "output keeps bounded head and tail", %{ctx: ctx, p: p} do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"
    command = "printf HEAD; awk 'BEGIN {for(i=0;i<50000;i++) printf \"x\"}'; printf TAIL"

    assert {:ok, output} =
             Tools.run("run_command", %{"command" => command, "timeout_ms" => 5000}, ctx, p)

    assert output =~ "HEAD"
    assert output =~ "TAIL"
    assert output =~ "truncated"
    assert byte_size(output) < 21_000
  end

  test "timeout kills shell and its background descendant before delayed mutation", %{
    root: root,
    ctx: ctx,
    p: p
  } do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"
    command = "(sleep 0.8; touch leaked) & wait"
    assert {:error, error} = Tools.run("run_command", %{"command" => command}, ctx, p)
    assert error =~ "timed out"
    Process.sleep(950)
    refute File.exists?(Path.join(root, "leaked"))
  end

  test "hard requester death cancels a command group independently of trapping exits", %{
    root: root,
    ctx: ctx
  } do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"
    parent = self()

    worker =
      spawn(fn ->
        Tools.run(
          "run_command",
          %{
            "command" => "printf started; (sleep 0.8; touch leaked) & wait",
            "timeout_ms" => 5000
          },
          ctx,
          fn _, text ->
            if text =~ "started", do: send(parent, :started)
            :ok
          end
        )
      end)

    assert_receive :started, 3000
    Process.exit(worker, :kill)
    Process.sleep(1100)
    refute File.exists?(Path.join(root, "leaked"))
  end

  test "a successful shell may not leave background work detached", %{root: root, ctx: ctx, p: p} do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"

    assert {:ok, output} =
             Tools.run(
               "run_command",
               %{"command" => "(sleep 0.8; touch leaked) >/dev/null 2>&1 & exit 0"},
               ctx,
               p
             )

    assert output =~ "exit code 0"
    Process.sleep(950)
    refute File.exists?(Path.join(root, "leaked"))
  end

  test "a stalled progress consumer cannot accumulate unbounded command output", %{ctx: ctx} do
    parent = self()

    worker =
      spawn(fn ->
        Tools.run("run_command", %{"command" => "yes x", "timeout_ms" => 5000}, ctx, fn _, text ->
          if text != "running" do
            send(parent, :blocked_progress)

            receive do
              :continue -> :ok
            end
          end

          :ok
        end)
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive :blocked_progress, 3000
    Process.sleep(200)
    assert {:message_queue_len, size} = Process.info(worker, :message_queue_len)
    assert size <= 6
    Process.exit(worker, :kill)
  end

  test "cooperative cancellation returns only after helper terminal exit", %{root: root, ctx: ctx} do
    parent = self()

    worker =
      spawn(fn ->
        result =
          Tools.run(
            "run_command",
            %{
              "command" => "printf started; (sleep 0.8; touch leaked) & wait",
              "timeout_ms" => 5000
            },
            ctx,
            fn _, text ->
              if text =~ "started" do
                {:links, links} = Process.info(self(), :links)
                send(parent, {:started, Enum.find(links, &is_port/1)})
              end

              :ok
            end
          )

        send(parent, {:result, result})
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:started, port}, 3000
    assert is_port(port)
    send(worker, :swarm_code_tool_cancel)
    assert_receive {:result, {:error, "command cancelled"}}, 1500
    assert Port.info(port) == nil
    Process.sleep(950)
    refute File.exists?(Path.join(root, "leaked"))
  end

  test "a finite slow progress callback still consumes a completed command", %{ctx: ctx} do
    assert {:ok, output} =
             Tools.run("run_command", %{"command" => "printf final"}, ctx, fn _, text ->
               if text == "final", do: Process.sleep(300)
               :ok
             end)

    assert output =~ "exit code 0"
    assert output =~ "final"
  end

  test "finite backpressure preserves the true command output tail", %{ctx: ctx} do
    callback = fn _, text ->
      if text =~ "HEAD", do: Process.sleep(800)
      :ok
    end

    command = "printf HEAD; awk 'BEGIN {for(i=0;i<40000;i++)printf \"x\"}'; printf TAIL"

    assert {:ok, output} =
             Tools.run(
               "run_command",
               %{"command" => command, "timeout_ms" => 5000},
               ctx,
               callback
             )

    assert output =~ "HEAD"
    assert String.ends_with?(output, "TAIL")
  end
end
