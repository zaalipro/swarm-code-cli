defmodule SwarmCodeCLI.Plain.Command do
  @moduledoc "Closed bounded line grammar producing neutral intents or local actions only."
  alias SwarmCodeCLI.Plain.{Lexer, Presenter}
  alias SwarmCodeCLI.UI.{Destination, LayerSpec, Intent, RequestResolver, SafeText}
  alias SafeText.Limits

  @settings_words "/settings needs the full-screen terminal; use swarmcode config here."

  @doc "cli74: what the plain presenter and a one-shot answer to `/settings` (`/config`, `/prefs`)."
  def settings_words, do: @settings_words

  def parse(line, %Presenter{} = presenter, scope) do
    if SwarmCodeCLI.UI.Keymap.settings_command?(line),
      do: settings_refusal(),
      else: parse_line(line, presenter, scope)
  end

  def parse(_, _, _), do: diagnostic()

  defp settings_refusal do
    {:ok, text} = SafeText.external(@settings_words, Limits.content())
    {:error, text}
  end

  defp parse_line(line, presenter, scope) do
    with {:ok, words} <- Lexer.words(line),
         {:ok, result} <- decode(words, presenter),
         :ok <- authorize(result, presenter, scope) do
      {:ok, result}
    else
      _ -> diagnostic(presenter, line)
    end
  end

  defp authorize({:local, _}, _, _), do: :ok

  defp authorize({:intent, intent}, p, scope) do
    with {:ok, _} <- Intent.validate(intent),
         {:ok, context} <- Presenter.context(p, intent, scope),
         do: RequestResolver.authorize(intent, context)
  end

  defp decode([verb | words], p) when verb in ["send", "queue"] do
    with {:ok, target, refs, text} <- compose(words, p, true),
         do: intent({:dispatch, if(verb == "send", do: :send, else: :queue), text, target, refs})
  end

  defp decode(["steer", run, node | words], p) do
    with true <- id?(run) and id?(node),
         true <- Map.has_key?(p.runs, run) and Map.has_key?(p.nodes, {run, node}),
         {:ok, :main, refs, text} <- compose(words, p, false),
         do: intent({:steer, run, node, text, refs})
  end

  defp decode(["answer", reference | options], p) do
    with {:ok, id, rev} <- reference(reference),
         %{kind: :question, state: :pending, expected_revision: ^rev, question: question} =
           interaction <- p.interactions[id],
         true <- question != nil and valid_refs?(options) and options != [],
         true <- question.multiple or length(options) == 1,
         true <- Enum.all?(options, fn id -> Enum.any?(question.options, &(&1.id == id)) end) do
      intent({:answer_question, interaction.run_id, interaction.node_id, id, rev, options})
    else
      _ -> :error
    end
  end

  defp decode([verb, reference], p) when verb in ["approve", "deny", "always-allow"] do
    with {:ok, id, rev} <- reference(reference),
         %{kind: :approval, state: :pending, expected_revision: ^rev} = i <- p.interactions[id] do
      decision =
        case verb do
          "approve" -> :approve
          "deny" -> :deny
          "always-allow" -> :always_allow
        end

      intent({:resolve_approval, i.run_id, i.node_id, id, rev, decision})
    else
      _ -> :error
    end
  end

  defp decode([verb, run], p) when verb in ["pause", "continue", "resume", "stop"] do
    operation =
      case verb do
        "pause" -> :pause
        "continue" -> :continue
        "resume" -> :resume
        "stop" -> :stop
      end

    if id?(run) and Map.has_key?(p.runs, run),
      do: intent({:run_control, operation, run}),
      else: :error
  end

  defp decode(["retry", reference], p) do
    with {:ok, run, rev} <- reference(reference),
         %{state: :failed, revision: ^rev} <- p.runs[run],
         do: intent({:retry_run, run, rev})
  end

  defp decode(["stop-agent", run, reference], p) do
    with true <- id?(run) and Map.has_key?(p.runs, run),
         {:ok, agent, rev} <- reference(reference),
         %{run_id: ^run, revision: ^rev} <- p.agents[{run, agent}],
         do: intent({:stop_agent, run, agent, rev})
  end

  defp decode(["seen", kind, ref], p) when kind in ["conversation", "run", "activity"] do
    {kind, table} =
      case kind do
        "conversation" -> {:conversation, p.conversations}
        "run" -> {:run, p.runs}
        "activity" -> {:activity, p.activities}
      end

    with {:ok, id, rev} <- reference(ref),
         %{revision: ^rev} <- table[id],
         do: intent({:mark_seen, kind, id, rev})
  end

  defp decode(["follow", panel], _) when panel in ["main", "inspector"],
    do: local({:scroll, panel, :follow})

  defp decode(["go", "conversation", id], p) do
    if id?(id) and Map.has_key?(p.conversations, id),
      do: local({:navigate, Destination.conversation(id)}),
      else: :error
  end

  defp decode(["go", "run", id], p) do
    if id?(id) and Map.has_key?(p.runs, id),
      do: local({:navigate, Destination.run(id)}),
      else: :error
  end

  defp decode(["activity"], _), do: local({:navigate, Destination.activity()})
  defp decode(["inspect", run], p), do: decode(["inspect", run, "overview"], p)

  defp decode(["inspect", run, tab], p)
       when tab in ["overview", "agents", "timeline", "changes"] do
    tab =
      case tab do
        "overview" -> :overview
        "agents" -> :agents
        "timeline" -> :timeline
        "changes" -> :changes
      end

    if id?(run) and Map.has_key?(p.runs, run),
      do: local({:open_layer, LayerSpec.run_inspector(run, tab)}),
      else: :error
  end

  defp decode(["detail", operation], _) when operation in ["next", "retry"],
    do: local({:detail_page, if(operation == "next", do: :next, else: :retry)})

  defp decode(["detail", ref], p) do
    with true <- id?(ref) and Map.has_key?(p.detail_refs, ref),
         %{run_id: run} <-
           Enum.find(Map.values(p.nodes) ++ Map.values(p.interactions), fn item ->
             Enum.any?(SwarmCodeCLI.UI.DataSource.DTO.Details.refs(item), &(&1.id == ref))
           end),
         do: local({:open_detail, run, ref})
  end

  defp decode(["back"], _), do: local(:back)
  defp decode(["help"], _), do: local({:open_layer, LayerSpec.help()})
  defp decode(["detach"], _), do: local({:quit_requested, :detach})

  defp decode([number], p) do
    prompts =
      p.interactions
      |> Map.values()
      |> Enum.filter(&(&1.kind == :question and &1.state == :pending and &1.question != nil))

    with true <- Regex.match?(~r/^[1-9][0-9]{0,2}$/, number),
         [prompt] <- prompts,
         true <-
           p.current_prompt != nil and p.current_prompt.id == prompt.id and
             p.current_prompt.expected_revision == prompt.expected_revision,
         option when not is_nil(option) <-
           Enum.at(prompt.question.options, String.to_integer(number) - 1) do
      decode(
        ["answer", prompt.id <> "@" <> Integer.to_string(prompt.expected_revision), option.id],
        p
      )
    else
      _ -> :error
    end
  end

  defp decode(_, _), do: :error
  defp compose(words, p, target?), do: options(words, p, target?, nil, [])

  defp options(["--" | words], p, _, target, refs) do
    text = Enum.join(words, " ")
    target = target || :main

    if Intent.valid_text?(text) and byte_size(text) <= 16_384 and valid_refs?(refs) and
         Enum.all?(refs, &(&1 in p.staged_refs)) and
         (target == :main or MapSet.member?(p.target_catalogue, target)),
       do: {:ok, target, refs, text},
       else: :error
  end

  defp options(["--target", value | rest], p, true, nil, refs) do
    with {:ok, target} <- target(value), do: options(rest, p, true, target, refs)
  end

  defp options(["--attach", ref | rest], p, target?, target, refs) when length(refs) < 16 do
    if id?(ref) and ref not in refs,
      do: options(rest, p, target?, target, refs ++ [ref]),
      else: :error
  end

  defp options(_, _, _, _, _), do: :error
  defp target("main"), do: {:ok, :main}

  defp target(value) do
    case String.split(value, ":", parts: 2) do
      [kind, id] when kind in ["reply", "thread", "revise", "command", "goal", "research"] ->
        target =
          case kind do
            "reply" -> {:reply, id}
            "thread" -> {:thread, id}
            "revise" -> {:revise, id}
            "command" -> {:chip, :command, id}
            "goal" -> {:chip, :goal, id}
            "research" -> {:chip, :research, id}
          end

        if id?(id), do: {:ok, target}, else: :error

      _ ->
        :error
    end
  end

  defp reference(value) do
    case String.split(value, "@", parts: 2) do
      [id, decimal] ->
        if id?(id) and decimal != "" and Regex.match?(~r/^[0-9]+$/, decimal) do
          significant = String.trim_leading(decimal, "0")

          cond do
            significant == "" ->
              {:ok, id, 0}

            byte_size(significant) > 20 ->
              :error

            true ->
              revision = String.to_integer(significant)
              if revision <= 18_446_744_073_709_551_615, do: {:ok, id, revision}, else: :error
          end
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp id?(id),
    do:
      is_binary(id) and byte_size(id) in 1..256 and
        Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/, id)

  defp valid_refs?(refs),
    do: length(refs) <= 16 and Enum.uniq(refs) == refs and Enum.all?(refs, &id?/1)

  defp intent(intent), do: {:ok, {:intent, intent}}
  defp local(action), do: {:ok, {:local, action}}

  defp diagnostic(p, line) do
    numbered? =
      is_binary(line) and byte_size(line) <= 5 and Regex.match?(~r/^[0-9]+(?:\r?\n)?$/, line)

    case {numbered?, p.current_prompt} do
      {true, %{kind: :question, question: %{options: [option | _]}} = prompt} ->
        message =
          "Use answer " <>
            prompt.id <>
            "@" <> Integer.to_string(prompt.expected_revision) <> " " <> option.id <> "."

        {:ok, text} = SafeText.external(message, Limits.content())
        {:error, text}

      _ ->
        diagnostic()
    end
  end

  defp diagnostic do
    {:ok, text} =
      SafeText.external(
        "Invalid command or unavailable subject. Use help; answers require answer ID@REV OPTION.",
        Limits.content()
      )

    {:error, text}
  end
end
