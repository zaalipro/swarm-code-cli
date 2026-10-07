defmodule SwarmCodeCLI.Plain.CommandTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.Plain.{Command, Lexer, Options, Presenter}
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.SafeText

  test "bounded lexer has literal single quotes and only four double quote escapes" do
    assert {:ok, ["send", "--", " a b ", "c\nd\t\"\\"]} =
             Lexer.words(~S(send -- ' a b ' "c\nd\t\"\\"))

    for line <- [
          ~S(send -- "\x"),
          "'unterminated",
          "a\\b",
          "a'bc'",
          "a\0b",
          <<255>>,
          String.duplicate("a", 16_385),
          String.duplicate("a ", 65),
          String.duplicate("a", 4_097)
        ] do
      assert {:error, _} = Lexer.words(line)
    end

    assert {:ok, ["help"]} = Lexer.words("help\r\n")
  end

  test "unknown commands and absent subjects are inert sanitized diagnostics" do
    p = Presenter.new(%Options{})
    scope = %Scope{kind: :conversation, id: "c", generation: 0}

    for line <- [
          "stop absent",
          "retry absent@0",
          "stop-agent absent a@0",
          "approve q@0",
          "inspect absent",
          "go run absent",
          "send -- hello",
          "1",
          "unknown"
        ] do
      assert {:error, %SafeText{} = error} = Command.parse(line, p, scope)
      refute SafeText.value(error) =~ "\e"
    end

    assert {:ok, {:local, {:quit_requested, :detach}}} = Command.parse("detach", p, scope)
  end

  test "every target form stays in the current catalogue and references preserve order" do
    row =
      Enum.find(
        SwarmCodeCLI.TestSupport.RequestConformance.domain_rows(),
        &(&1["name"] == "send")
      )

    p = SwarmCodeCLI.TestSupport.RequestConformance.presenter(row)

    for {word, target} <- [
          {"main", :main},
          {"reply:node-a2", {:reply, "node-a2"}},
          {"thread:node-a2", {:thread, "node-a2"}},
          {"revise:node-a2", {:revise, "node-a2"}},
          {"command:cmd", {:chip, :command, "cmd"}},
          {"goal:goal", {:chip, :goal, "goal"}},
          {"research:topic", {:chip, :research, "topic"}}
        ] do
      current = %{p | target_catalogue: MapSet.new([target]), staged_refs: ["a", "b"]}

      assert {:ok, {:intent, {:dispatch, :send, " edge Café ", ^target, ["b", "a"]}}} =
               Command.parse(
                 "send --target " <> word <> " --attach b --attach a -- ' edge Café '",
                 current,
                 p.scope
               )

      if target != :main do
        assert {:error, _} = Command.parse("send --target " <> word <> " -- x", p, p.scope)
      end
    end
  end

  test "revision decoder accepts exact uint64 maximum and denies overflow without atom creation" do
    row =
      Enum.find(
        SwarmCodeCLI.TestSupport.RequestConformance.domain_rows(),
        &(&1["name"] == "retry")
      )

    p = SwarmCodeCLI.TestSupport.RequestConformance.presenter(row)
    maximum = 18_446_744_073_709_551_615
    p = put_in(p.runs["run-a2"].revision, maximum)

    assert {:ok, {:intent, {:retry_run, "run-a2", ^maximum}}} =
             Command.parse("retry run-a2@18446744073709551615", p, p.scope)

    assert {:error, _} = Command.parse("retry run-a2@18446744073709551616", p, p.scope)
    assert {:error, _} = Command.parse("retry run-a2@000000000000000000000", p, p.scope)
    zero = put_in(p.runs["run-a2"].revision, 0)

    assert {:ok, {:intent, {:retry_run, "run-a2", 0}}} =
             Command.parse("retry run-a2@000000000000000000000", zero, zero.scope)
  end

  test "word and physical line limits admit their exact boundary" do
    word = String.duplicate("a", 4096)
    assert {:ok, [^word]} = Lexer.words(word)
    assert {:ok, words} = Lexer.words(Enum.join(List.duplicate("a", 64), " "))
    assert length(words) == 64
    line = Enum.join([word, word, word, String.duplicate("b", 4093)], " ")
    assert byte_size(line) == 16384
    assert {:ok, _} = Lexer.words(line <> "\r\n")
    assert {:error, _} = Lexer.words(line <> "x")
    assert {:error, _} = Lexer.words("send -- a\u00a0b")
    assert {:ok, ["send", "--", "a\u00a0b"]} = Lexer.words("send -- 'a\u00a0b'")
  end

  # cli020 B22 (tui-code-18): the finer approval decisions, offered only when
  # the row lists them.
  describe "approve-run, always-prefix and deny-stop" do
    alias SwarmCodeCLI.UI.DataSource.{Delivery, DTO}

    defp approval_presenter(decisions) do
      scope = %Scope{kind: :global, id: nil, generation: 0}

      approval = %DTO.PendingInteraction{
        id: "approval",
        run_id: "r",
        node_id: "n",
        conversation_id: "c",
        kind: :approval,
        expected_revision: 7,
        allowed_actions: [:approve, :deny, :always_allow],
        approval: %DTO.Approval{
          tool: "run_command",
          permission: :execute,
          arguments_preview: "mix test",
          command: "mix test",
          command_family: "mix test",
          classification: :normal,
          allowed_decisions: decisions
        }
      }

      item = %DTO.ActivityItem{
        id: "activity-approval",
        run_id: "r",
        conversation_id: "c",
        kind: :approval,
        state: :waiting_approval,
        revision: 7,
        interaction: approval
      }

      delivery = %Delivery{
        kind: :watch_ready,
        watch_ref: "w",
        request_id: nil,
        sequence: nil,
        scope: scope,
        generation: 0,
        revision: 1,
        body: %DTO.ActivitySnapshot{items: [item], counts: %DTO.Counts{}}
      }

      {p, records} = Presenter.present(Presenter.new(%Options{}), "epoch", delivery)
      {p, scope, records |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()}
    end

    test "each verb resolves with its decision when offered" do
      {p, scope, out} =
        approval_presenter([:approve, :approve_run, :always_prefix, :deny, :deny_stop])

      for {verb, decision} <- [
            {"approve-run", :approve_run},
            {"always-prefix", :always_prefix},
            {"deny-stop", :deny_stop}
          ] do
        assert {:ok, {:intent, {:resolve_approval, "r", "n", "approval", 7, ^decision}}} =
                 Command.parse("#{verb} approval@7", p, scope),
               verb

        assert out =~ "#{verb} approval@7"
      end
    end

    test "a read-only row offers approve, deny and deny-stop only" do
      {p, scope, out} = approval_presenter([:approve, :deny, :deny_stop])
      assert {:ok, {:intent, _}} = Command.parse("deny-stop approval@7", p, scope)
      assert {:error, %SafeText{}} = Command.parse("approve-run approval@7", p, scope)
      assert {:error, %SafeText{}} = Command.parse("always-prefix approval@7", p, scope)
      refute out =~ "approve-run"
    end
  end
end
