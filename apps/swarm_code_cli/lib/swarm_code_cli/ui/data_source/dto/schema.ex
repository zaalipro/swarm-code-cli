defmodule SwarmCodeCLI.UI.DataSource.DTO.Schema do
  @moduledoc false
  alias SwarmCodeCLI.UI.Intent
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO}

  defmacro __using__(opts) do
    fields = Keyword.fetch!(opts, :fields)
    defaults = Keyword.fetch!(opts, :defaults)
    types = Enum.map(fields, fn {field, type} -> {field, type_ast(type)} end)

    quote do
      @schema unquote(fields)
      defstruct unquote(defaults)
      @type t :: %__MODULE__{unquote_splicing(types)}
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
        do: SwarmCodeCLI.UI.DataSource.DTO.Schema.decode(__MODULE__, @schema, value)
    end
  end

  defp type_ast(:id), do: quote(do: binary())
  defp type_ast(:text), do: quote(do: binary())
  defp type_ast(:revision), do: quote(do: non_neg_integer())
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

  def valid?(:revision, value),
    do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991

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
        else: [:pause, :continue, :resume, :stop, :retry, :steer, :inspect, :copy, :fork]

    Enum.all?(run.allowed_actions, &(&1 in actions)) and
      (:retry not in run.allowed_actions or run.state == :failed)
  end

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
        do: not is_nil(interaction.question),
        else: is_nil(interaction.question)
      )
  end

  def relations?(%{__struct__: DTO.Outcome} = outcome) do
    case outcome.status do
      :needs_input -> not is_nil(outcome.interaction) and is_nil(outcome.error)
      :rejected -> not is_nil(outcome.error) and is_nil(outcome.interaction)
      _ -> is_nil(outcome.interaction)
    end
  end

  def relations?(%{state: :superseded, allowed_actions: actions}),
    do: Enum.all?(actions, &(&1 in [:inspect, :copy, :fork]))

  def relations?(%{state: state, request_id: request_id, error: error}) do
    case state do
      :error ->
        not is_nil(error) and not is_nil(request_id)

      loading when loading in [:loading_before, :loading_after] ->
        not is_nil(request_id) and is_nil(error)

      _ ->
        is_nil(error)
    end
  end

  def relations?(_), do: true

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
