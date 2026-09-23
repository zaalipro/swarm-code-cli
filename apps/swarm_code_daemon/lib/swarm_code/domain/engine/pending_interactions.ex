defmodule SwarmCode.Domain.Engine.PendingInteractions do
  @moduledoc """
  CLI-local (not synced from the desktop): the bounded, redacted projection of
  what a run is waiting on, and the validation of one indexed question answer.
  `RunServer.pending_interactions/1` and `RunServer.answer_question/5` are the
  only callers; keeping the pure part here keeps the recorded RunServer patch
  (`provenance/patches/…/run_server.ex.diff`) small.

  Every row has the same keys, so the service boundary can decode it without
  guessing (pass 70 contract, frozen; see `docs/superpowers/plans/pass70-notes/A.md`):

    * `node_id` — the node that waits: the **op** node for an approval, the
      `ask_user` op for a question. It is the id `RunServer.resolve_approval/3`
      and `answer_question/5` take.
    * `agent_id` — the agent node that owns that op (its parent), or nil.
    * `kind` — `:approval | :question`.
    * `permission` — `:read | :write | :execute`, nil for a question.
    * `tool` — the op type (`"run_command"`, `"edit_file"`, an MCP tool …), nil
      for a question.
    * `args` — the call's arguments as JSON (≤ 8 KiB, secrets redacted).
    * `command` — the shell command of a `run_command` (≤ 2 000 bytes,
      redacted), else nil.
    * `cwd` — where a `run_command` runs (the project root joined with its
      `workdir`), the project root for any other approval, nil for a question.
    * `path` — the `path` argument of a file tool, else nil.
    * `reason` — the model's `justification` argument (≤ 500 bytes), or nil.
    * `command_family` — the family `"Always allow"` would remember (the
      server-computed `approval_prefix`), nil when nothing may be remembered
      (a dangerous command, any tool other than `run_command`).
    * `classification` — `:safe | :normal | :dangerous` from `CommandSafety`,
      nil for a question.
    * `allowed_decisions` — the wire decisions that mean something here:
      `:approve`, `:approve_run` (→ `resolve_approval(…, :always)`: every call
      of this tool for the rest of the run), `:always_prefix` (only with a
      family; → `{:always_prefix, family}`), `:deny`, `:deny_stop`. `[]` for a
      question.
    * `requested_at` — `DateTime` (UTC) when the run started waiting.
    * `questions` — for a question row, the unanswered questions
      (`%{index, question, options: [%{label, description}], multiple}`),
      `[]` for an approval.
  """

  alias SwarmCode.Domain.Tools.CommandSafety

  @max_rows 64

  @doc "The rows for a run's pending approvals and questions, at most #{@max_rows}."
  @spec rows(map(), map(), map(), String.t() | nil) :: [map()]
  def rows(approvals, questions, nodes, project_root) do
    approval_rows =
      approvals
      |> Enum.take(@max_rows)
      |> Enum.map(fn {node_id, approval} ->
        approval_row(node_id, approval, Map.get(nodes, node_id), project_root)
      end)

    question_rows =
      questions
      |> Enum.take(@max_rows - length(approval_rows))
      |> Enum.map(fn {node_id, entry} ->
        question_row(node_id, entry, Map.get(nodes, node_id))
      end)

    Enum.take(approval_rows ++ question_rows, @max_rows)
  end

  @doc false
  @spec approval_row(String.t(), map(), map() | nil, String.t() | nil) :: map()
  def approval_row(node_id, approval, node, project_root) do
    node = node || %{}
    tool = bound_text(Map.get(node, :op_type), 128)
    input = decoded_input(Map.get(node, :input))
    family = bound_nonempty(Map.get(node, :approval_prefix), 500)
    classification = classification(approval, tool, input)

    %{
      node_id: node_id,
      agent_id: Map.get(node, :parent_id),
      kind: :approval,
      permission: Map.get(approval, :permission),
      tool: tool,
      args: bound_args(Map.get(node, :input)),
      command: if(tool == "run_command", do: string_arg(input, "command", 2_000)),
      cwd: cwd(tool, input, project_root),
      path: string_arg(input, "path", 1_000),
      reason: string_arg(input, "justification", 500),
      command_family: family,
      classification: classification,
      allowed_decisions:
        [:approve, :approve_run] ++
          if(family && classification != :dangerous, do: [:always_prefix], else: []) ++
          [:deny, :deny_stop],
      requested_at: Map.get(approval, :requested_at),
      questions: []
    }
  end

  @doc false
  @spec question_row(String.t(), map(), map() | nil) :: map()
  def question_row(node_id, entry, node) do
    %{
      node_id: node_id,
      agent_id: Map.get(node || %{}, :parent_id),
      kind: :question,
      permission: nil,
      tool: nil,
      args: "{}",
      command: nil,
      cwd: nil,
      path: nil,
      reason: nil,
      command_family: nil,
      classification: nil,
      allowed_decisions: [],
      requested_at: Map.get(entry, :requested_at),
      questions: unanswered_question_data(entry)
    }
  end

  @doc "The question entry of `node_id` when question `index` is still unanswered."
  @spec pending_question_entry(map(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, :stale_question}
  def pending_question_entry(questions, node_id, index) do
    case Map.get(questions, node_id) do
      nil ->
        {:error, :stale_question}

      entry ->
        if Map.has_key?(Map.get(entry, :answers, %{}), index),
          do: {:error, :stale_question},
          else: {:ok, entry}
    end
  end

  @doc "Validates one indexed answer against the asked options."
  @spec validated_answer(list(), term(), term(), term()) ::
          {:ok, map()} | {:error, :invalid_answer}
  def validated_answer(questions, index, indices, custom)
      when is_list(questions) and length(questions) in 1..4 and
             is_integer(index) and index >= 0 and index < length(questions) and
             is_list(indices) and length(indices) <= 12 and
             is_binary(custom) and byte_size(custom) <= 4_000 do
    question = Enum.at(questions, index)
    options = if is_map(question), do: question["options"] || question[:options] || [], else: []

    multi =
      is_map(question) and (question["multi_select"] == true or question[:multi_select] == true)

    if is_list(options) and String.valid?(custom) and
         (indices != [] or String.trim(custom) != "") and
         (multi or length(indices) <= 1) and
         length(indices) == length(Enum.uniq(indices)) and
         Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < min(length(options), 12))) do
      labels = Enum.map(indices, fn i -> original_option_label(Enum.at(options, i)) end)

      if Enum.all?(labels, &is_binary/1),
        do: {:ok, %{"labels" => labels, "custom" => custom}},
        else: {:error, :invalid_answer}
    else
      {:error, :invalid_answer}
    end
  end

  def validated_answer(_questions, _index, _indices, _custom), do: {:error, :invalid_answer}

  # -- approval fields ---------------------------------------------------------

  # The class the server stored when the approval was raised (spec 66 T4); for
  # an approval raised without one, the command's own class.
  defp classification(%{safety: safety}, _tool, _input)
       when safety in [:safe, :normal, :dangerous],
       do: safety

  defp classification(_approval, "run_command", input),
    do: CommandSafety.classify(Map.get(input, "command"))

  defp classification(_approval, _tool, _input), do: :normal

  defp cwd(_tool, _input, root) when not is_binary(root) or root == "", do: nil

  defp cwd("run_command", input, root) do
    case Map.get(input, "workdir") do
      workdir when is_binary(workdir) and workdir != "" ->
        bound_text(Path.expand(workdir, root), 1_000)

      _none ->
        bound_text(root, 1_000)
    end
  end

  defp cwd(_tool, _input, root), do: bound_text(root, 1_000)

  defp string_arg(input, key, max) do
    case Map.get(input, key) do
      value when is_binary(value) and value != "" -> bound_text(value, max)
      _other -> nil
    end
  end

  defp bound_nonempty(value, max) when is_binary(value) and value != "",
    do: bound_text(value, max)

  defp bound_nonempty(_value, _max), do: nil

  # The node input is already an 8 KiB JSON prefix; a longer (corrupted/legacy)
  # value is not decoded at all.
  defp decoded_input(input) when is_binary(input) and byte_size(input) <= 8_192 do
    case Jason.decode(input) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defp decoded_input(_input), do: %{}

  # -- question fields ---------------------------------------------------------

  defp original_option_label(%{"label" => label}) when is_binary(label), do: label
  defp original_option_label(%{label: label}) when is_binary(label), do: label
  defp original_option_label(label) when is_binary(label), do: label
  defp original_option_label(_), do: nil

  defp unanswered_question_data(entry) do
    entry
    |> Map.get(:questions)
    |> bound_list(4)
    |> Enum.with_index()
    |> Enum.reject(fn {_q, index} -> Map.has_key?(Map.get(entry, :answers, %{}), index) end)
    |> Enum.map(fn {q, index} -> bound_question_data(q, index) end)
  end

  # This projection crosses a process boundary. Keep it independent of the
  # runtime maps and reject malformed input instead of reflecting it verbatim.
  defp bound_question_data(question, index) when is_map(question) do
    %{
      index: index,
      question: bound_text(question["question"] || question[:question], 4_000),
      options:
        bound_list(question["options"] || question[:options], 12) |> Enum.map(&bound_option/1),
      multiple: question["multi_select"] == true or question[:multi_select] == true
    }
  end

  defp bound_question_data(_, index),
    do: %{index: index, question: "", options: [], multiple: false}

  defp bound_option(option) when is_map(option) do
    %{
      label: bound_text(option["label"] || option[:label], 500),
      description: bound_text(option["description"] || option[:description], 500)
    }
  end

  defp bound_option(option), do: %{label: bound_text(option, 500), description: ""}
  defp bound_list(list, count) when is_list(list), do: Enum.take(list, count)
  defp bound_list(_, _), do: []

  # -- bounding and redaction ----------------------------------------------------

  # Do not return truncated raw JSON that could include credentials: decode,
  # redact, re-encode, then bound.
  defp bound_args(input) do
    case decoded_input(input) do
      map when map_size(map) == 0 -> "{}"
      map -> map |> bound_value(0) |> Jason.encode!() |> bound_text(8_192)
    end
  end

  defp bound_value(_, depth) when depth > 4, do: "[TRUNCATED]"
  defp bound_value(value, _) when is_binary(value), do: bound_text(value, 2_000)

  defp bound_value(value, depth) when is_list(value),
    do: value |> Enum.take(16) |> Enum.map(&bound_value(&1, depth + 1))

  defp bound_value(value, depth) when is_map(value) do
    value
    |> Enum.take(16)
    |> Map.new(fn {key, item} ->
      key = to_string(key)
      normalized = String.downcase(key) |> String.replace(~r/[^a-z0-9]/, "")

      secret? =
        Enum.any?(
          ~w(apikey token secret authorization password credential cookie headers env privatekey),
          &String.contains?(normalized, &1)
        )

      {bound_text(key, 128), if(secret?, do: "[REDACTED]", else: bound_value(item, depth + 1))}
    end)
  end

  defp bound_value(value, _) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp bound_value(_, _), do: nil

  @doc false
  @spec bound_text(term(), pos_integer()) :: String.t()
  def bound_text(value, max) when is_binary(value) do
    # Validate only a bounded prefix; copy it so a multi-MB source is not retained.
    prefix = binary_part(value, 0, min(byte_size(value), max))

    case :unicode.characters_to_binary(prefix) do
      result when is_binary(result) -> result |> redact_preview() |> byte_prefix(max)
      {:incomplete, valid, _} -> valid |> redact_preview() |> byte_prefix(max)
      {:error, valid, _} -> valid |> redact_preview() |> byte_prefix(max)
    end
  end

  def bound_text(_, _), do: ""

  defp redact_preview(text) do
    text
    |> SwarmCode.Domain.LLM.HTTP.redact()
    |> String.replace(
      ~r/((?:api[_-]?key|access[_-]?token|password|secret)\s*[=:]\s*)[^\s,;]+/i,
      "\\1[REDACTED]"
    )
  end

  defp byte_prefix(value, max) when byte_size(value) <= max, do: :binary.copy(value)

  defp byte_prefix(value, max) do
    prefix = binary_part(value, 0, max)
    if String.valid?(prefix), do: :binary.copy(prefix), else: byte_prefix(value, max - 1)
  end
end
