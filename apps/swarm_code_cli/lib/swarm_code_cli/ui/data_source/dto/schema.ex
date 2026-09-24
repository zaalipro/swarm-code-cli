defmodule SwarmCodeCLI.UI.DataSource.DTO.Schema do
  @moduledoc false
  alias SwarmCodeCLI.UI.Intent
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO}

  defmacro __using__(opts) do
    fields = Keyword.fetch!(opts, :fields)
    defaults = Keyword.fetch!(opts, :defaults)
    wire_defaults = Keyword.get(opts, :wire_defaults, [])
    types = Enum.map(fields, fn {field, type} -> {field, type_ast(type)} end)

    quote do
      @schema unquote(fields)
      @wire_defaults unquote(wire_defaults)
      defstruct unquote(defaults)
      @type t :: %__MODULE__{unquote_splicing(types)}
      @doc false
      def __wire_defaults__, do: @wire_defaults
      @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
      def validate(%__MODULE__{} = value) do
        valid =
          map_size(value) == length(@schema) + 1 and
            Enum.all?(@schema, fn {key, type} ->
              Map.has_key?(value, key) and
                SwarmCodeCLI.UI.DataSource.DTO.Schema.valid?(type, Map.fetch!(value, key))
            end) and
            SwarmCodeCLI.UI.DataSource.DTO.Schema.relations?(value)

        if valid, do: {:ok, value}, else: {:error, :invalid_dto}
      end

      def validate(_), do: {:error, :invalid_dto}
      @doc "Decode exact string keys and closed enum values; reject extra or missing fields."
      def decode(value),
        do:
          SwarmCodeCLI.UI.DataSource.DTO.Schema.decode(__MODULE__, @schema, value, @wire_defaults)
    end
  end

  defp type_ast(:id), do: quote(do: binary())
  defp type_ast(:text), do: quote(do: binary())
  defp type_ast({:text, _max_bytes}), do: quote(do: binary())
  defp type_ast(:revision), do: quote(do: non_neg_integer())
  defp type_ast(:count), do: quote(do: non_neg_integer())
  defp type_ast(:float), do: quote(do: float())
  defp type_ast(:progress), do: quote(do: 0..100)
  defp type_ast(:boolean), do: quote(do: boolean())
  defp type_ast(:error), do: quote(do: AdmissionError.t())
  defp type_ast(:actions), do: quote(do: [Intent.permission() | :inspect | :copy | :fork])

  defp type_ast({:enum, choices}),
    do: Enum.reduce(choices, fn choice, acc -> {:|, [], [choice, acc]} end)

  defp type_ast({:optional, type}), do: {:|, [], [type_ast(type), nil]}
  defp type_ast({:list, type}), do: [type_ast(type)]
  defp type_ast({:dto, module}), do: {{:., [], [module, :t]}, [], []}

  def valid?(:id, value), do: Intent.valid_id?(value)

  def valid?(:text, value),
    do: is_binary(value) and byte_size(value) <= 65_536 and String.valid?(value)

  def valid?({:text, max_bytes}, value),
    do: is_binary(value) and byte_size(value) <= max_bytes and String.valid?(value)

  def valid?(:revision, value),
    do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991

  # Counters, byte sizes and unix-millisecond instants share the revision range.
  def valid?(:count, value), do: valid?(:revision, value)

  # Money and other non-negative measures; JSON may carry a whole number.
  def valid?(:float, value),
    do: is_number(value) and value >= 0 and value <= 9_007_199_254_740_991

  def valid?(:progress, value), do: is_integer(value) and value in 0..100
  def valid?(:boolean, value), do: is_boolean(value)
  def valid?({:enum, choices}, value), do: value in choices
  def valid?({:optional, _}, nil), do: true
  def valid?({:optional, type}, value), do: valid?(type, value)
  def valid?({:list, type}, values), do: bounded_list?(values, 200, &valid?(type, &1))

  def valid?(:actions, values),
    do:
      bounded_list?(values, 20, &(&1 in (Intent.permissions() ++ [:inspect, :copy, :fork]))) and
        Enum.uniq(values) == values

  def valid?(:error, value), do: match?({:ok, _}, AdmissionError.validate(value))
  def valid?({:dto, module}, value), do: match?({:ok, _}, module.validate(value))
  def valid?(_, _), do: false

  def bounded_list?([], _, _), do: true

  def bounded_list?([value | rest], left, predicate) when left > 0,
    do: predicate.(value) and bounded_list?(rest, left - 1, predicate)

  def bounded_list?(_, _, _), do: false

  def relations?(%{__struct__: DTO.RunSummary} = run) do
    actions =
      if run.state == :superseded,
        do: [:inspect, :copy, :fork],
        else: [
          :pause,
          :continue,
          :resume,
          :stop,
          :retry,
          :steer,
          :mark_seen,
          :inspect,
          :copy,
          :fork
        ]

    Enum.all?(run.allowed_actions, &(&1 in actions)) and
      (:retry not in run.allowed_actions or run.state == :failed) and
      run.seen_revision <= run.revision and run.parent_run_id != run.id
  end

  def relations?(%{__struct__: DTO.DetailRef} = ref), do: ref.total_bytes in 1..16_777_216

  def relations?(%{__struct__: DTO.DetailWindow, state: :error} = page),
    do:
      is_nil(page.detail_ref) and page.text == "" and is_nil(page.next_offset) and
        not is_nil(page.error)

  def relations?(%{__struct__: DTO.DetailWindow, state: :idle} = page) do
    end_offset = page.offset + byte_size(page.text)

    not is_nil(page.detail_ref) and is_nil(page.error) and
      page.offset < page.detail_ref.total_bytes and byte_size(page.text) > 0 and
      end_offset <= page.detail_ref.total_bytes and
      page.next_offset == if(end_offset == page.detail_ref.total_bytes, do: nil, else: end_offset)
  end

  def relations?(%{__struct__: DTO.TranscriptItem} = item) do
    SwarmCodeCLI.UI.Intent.valid_id_list?(item.attachment_refs) and
      (is_nil(item.detail_ref) or byte_size(item.text) < item.detail_ref.total_bytes) and
      (is_nil(item.reasoning_detail_ref) or
         byte_size(item.reasoning) < item.reasoning_detail_ref.total_bytes) and
      if(item.target_kind == :main, do: is_nil(item.target_id), else: not is_nil(item.target_id)) and
      (item.state != :superseded or
         Enum.all?(item.allowed_actions, &(&1 in [:inspect, :copy, :fork])))
  end

  def relations?(%{__struct__: DTO.WorkspaceSnapshot} = page),
    do:
      Enum.all?(page.allowed_actions, &(&1 in [:send, :queue, :mark_seen])) and
        page.seen_revision <= page.revision and page_relation?(page)

  def relations?(%{__struct__: DTO.ActivityItem} = item),
    do:
      item.seen_revision <= item.revision and
        (item.state != :superseded or
           Enum.all?(item.allowed_actions, &(&1 in [:inspect, :copy, :fork])))

  def relations?(%{__struct__: DTO.AgentSummary} = agent) do
    actions =
      if agent.launched_by_superseded, do: [:stop_agent], else: [:stop_agent, :inspect, :copy]

    Enum.all?(agent.allowed_actions, &(&1 in actions))
  end

  def relations?(%{__struct__: DTO.Question, options: options}) do
    options != [] and length(options) <= 16 and Enum.uniq_by(options, & &1.id) == options
  end

  def relations?(%{__struct__: DTO.PendingInteraction} = interaction) do
    actions =
      case {interaction.state, interaction.kind} do
        {:resolved, _} -> []
        {:pending, :question} -> [:answer_question]
        {:pending, :approval} -> [:approve, :deny, :always_allow]
      end

    Enum.all?(interaction.allowed_actions, &(&1 in actions)) and
      if(interaction.kind == :question,
        do: not is_nil(interaction.question) and is_nil(interaction.approval),
        else: is_nil(interaction.question)
      )
  end

  def relations?(%{__struct__: DTO.Approval} = approval) do
    String.trim(approval.tool) != "" and
      (is_nil(approval.arguments_detail_ref) or
         byte_size(approval.arguments_preview) < approval.arguments_detail_ref.total_bytes) and
      Enum.uniq(approval.allowed_decisions) == approval.allowed_decisions and
      (:always_prefix not in approval.allowed_decisions or
         (is_binary(approval.command_family) and String.trim(approval.command_family) != ""))
  end

  def relations?(%{__struct__: DTO.ConversationList} = page),
    do:
      Enum.uniq_by(page.items, & &1.id) == page.items and
        Enum.count(page.items, & &1.current) <= 1 and page_relation?(page)

  def relations?(%{__struct__: DTO.RateLimit} = limit), do: limit.used_percent <= 100

  def relations?(%{__struct__: DTO.Refusal} = refusal),
    do: String.trim(refusal.code) != "" and String.trim(refusal.text) != ""

  def relations?(%{__struct__: DTO.Outcome} = outcome) do
    (is_nil(outcome.feedback) or outcome.status == :accepted) and
      (is_nil(outcome.disposition) or outcome.status == :accepted) and
      (is_nil(outcome.reason) or outcome.status == :rejected) and
      case outcome.status do
        :needs_input -> not is_nil(outcome.interaction) and is_nil(outcome.error)
        :rejected -> not is_nil(outcome.error) and is_nil(outcome.interaction)
        _ -> is_nil(outcome.interaction)
      end
  end

  def relations?(%{__struct__: DTO.Feedback} = feedback) do
    byte_size(feedback.title) <= 256 and
      case feedback.kind do
        :navigate -> not is_nil(feedback.feature) and feedback.text == ""
        kind when kind in [:report, :notice] -> is_nil(feedback.feature) and feedback.text != ""
      end
  end

  def relations?(%{state: :superseded, allowed_actions: actions}),
    do: Enum.all?(actions, &(&1 in [:inspect, :copy, :fork]))

  def relations?(%{state: _, request_id: _, error: _} = page), do: page_relation?(page)

  def relations?(%{__struct__: SwarmCodeCLI.UI.DataSource.DTO.FormField} = f) do
    Enum.all?([f.key, f.label, f.value, f.hint], &String.valid?/1) and
      byte_size(f.key) <= 16_384 and byte_size(f.label) <= 16_384 and
      byte_size(f.value) <= 16_384 and byte_size(f.hint) <= 16_384 and
      length(f.choices) <= 64 and
      Enum.all?(f.choices, &(String.valid?(&1) and byte_size(&1) <= 16_384)) and
      Enum.uniq(f.choices) == f.choices
  end

  def relations?(%{__struct__: SwarmCodeCLI.UI.DataSource.DTO.FeatureForm} = f) do
    String.valid?(f.title) and String.valid?(f.submit_label) and
      byte_size(f.title) <= 16_384 and byte_size(f.submit_label) <= 16_384 and
      length(f.fields) <= 32 and Enum.uniq_by(f.fields, & &1.key) == f.fields and
      Enum.all?(f.fields, &relations?/1)
  end

  def relations?(_), do: true

  defp page_relation?(%{state: state, request_id: request_id, error: error}) do
    case state do
      :error ->
        not is_nil(error) and not is_nil(request_id)

      loading when loading in [:loading_before, :loading_after] ->
        not is_nil(request_id) and is_nil(error)

      _ ->
        is_nil(error)
    end
  end

  def decode(module, schema, map, defaults) when is_map(map) and not is_struct(map) do
    map =
      Enum.reduce(defaults, map, fn {key, value}, acc ->
        Map.put_new(acc, Atom.to_string(key), value)
      end)

    decode(module, schema, map)
  end

  def decode(_, _, _, _), do: {:error, :invalid_dto}

  def decode(module, schema, map) when is_map(map) and not is_struct(map) do
    if map_size(map) == length(schema) do
      Enum.reduce_while(schema, {:ok, []}, fn {key, type}, {:ok, acc} ->
        with {:ok, wire} <- Map.fetch(map, Atom.to_string(key)),
             {:ok, value} <- decode_value(type, wire) do
          {:cont, {:ok, [{key, value} | acc]}}
        else
          _ -> {:halt, {:error, :invalid_dto}}
        end
      end)
      |> case do
        {:ok, fields} -> module.validate(struct!(module, fields))
        error -> error
      end
    else
      {:error, :invalid_dto}
    end
  end

  def decode(_, _, _), do: {:error, :invalid_dto}

  defp decode_value({:enum, choices}, value) when is_binary(value) do
    case Enum.find(choices, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_dto}
      atom -> {:ok, atom}
    end
  end

  defp decode_value({:enum, _choices}, _value), do: {:error, :invalid_dto}

  defp decode_value(:actions, values) do
    choices = Intent.permissions() ++ [:inspect, :copy, :fork]
    decode_list({:enum, choices}, values, 20)
  end

  defp decode_value({:optional, _}, nil), do: {:ok, nil}
  defp decode_value({:optional, type}, value), do: decode_value(type, value)
  defp decode_value({:list, type}, values), do: decode_list(type, values, 200)
  defp decode_value({:dto, module}, value), do: module.decode(value)
  defp decode_value(:error, value), do: AdmissionError.decode(value)

  defp decode_value(:float, value) when is_integer(value),
    do: decode_value(:float, value * 1.0)

  defp decode_value(type, value),
    do: if(valid?(type, value), do: {:ok, value}, else: {:error, :invalid_dto})

  defp decode_list(type, values, limit) do
    if bounded_list?(values, limit, fn _ -> true end) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case decode_value(type, value) do
          {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
          _ -> {:halt, {:error, :invalid_dto}}
        end
      end)
      |> case do
        {:ok, list} -> {:ok, Enum.reverse(list)}
        error -> error
      end
    else
      {:error, :invalid_dto}
    end
  end
end
