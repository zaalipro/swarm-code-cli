defmodule SwarmCodeCLI.UI.Intent do
  @moduledoc """
  The closed renderer- and presenter-neutral domain request vocabulary.

  All textual identifiers are bounded before they are inspected. Runtime
  strings are never converted to atoms.
  """

  @max_id_bytes 256
  @max_text_bytes 262_144
  @max_references 16

  @permissions [
    :send,
    :queue,
    :steer,
    :pause,
    :continue,
    :resume,
    :stop,
    :retry,
    :stop_agent,
    :answer_question,
    :approve,
    :deny,
    :always_allow,
    :approve_run,
    :always_prefix,
    :deny_stop,
    :mark_seen
  ]

  # How the desktop answers an approval: once, for the rest of the run, always
  # for the command's family, deny, or deny and stop the run. `:always_allow`
  # is the older "always" the daemon still understands.
  @decisions [:approve, :approve_run, :always_prefix, :always_allow, :deny, :deny_stop]

  @type dispatch_target ::
          :main
          | {:reply, binary()}
          | {:thread, binary()}
          | {:revise, binary()}
          | {:chip, :command | :goal | :research, binary()}

  @type permission ::
          :send
          | :queue
          | :steer
          | :pause
          | :continue
          | :resume
          | :stop
          | :retry
          | :stop_agent
          | :answer_question
          | :approve
          | :deny
          | :always_allow
          | :approve_run
          | :always_prefix
          | :deny_stop
          | :mark_seen

  @type decision :: :approve | :approve_run | :always_prefix | :always_allow | :deny | :deny_stop

  @type t ::
          {:dispatch, :send | :queue, binary(), dispatch_target(), [binary()]}
          | {:steer, binary(), binary(), binary(), [binary()]}
          | {:run_control, :pause | :continue | :resume | :stop, binary()}
          | {:retry_run, binary(), non_neg_integer()}
          | {:stop_agent, binary(), binary(), non_neg_integer()}
          | {:answer_question, binary(), binary(), binary(), non_neg_integer(),
             [binary()] | %{option_ids: [binary()], custom_text: binary()}}
          | {:resolve_approval, binary(), binary(), binary(), non_neg_integer(), decision()}
          | {:mark_seen, :conversation | :run | :activity, binary(), non_neg_integer()}

  @spec permissions() :: [permission()]
  def permissions, do: @permissions

  @doc "Every approval decision, in the order the keys offer them."
  @spec decisions() :: [decision()]
  def decisions, do: @decisions

  @spec permission?(term()) :: boolean()
  def permission?(permission), do: permission in @permissions

  @spec valid_id?(term()) :: boolean()
  def valid_id?(value)
      when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= @max_id_bytes do
    String.valid?(value) and control_free?(value)
  end

  def valid_id?(_value), do: false

  @spec valid_text?(term()) :: boolean()
  def valid_text?(value)
      when is_binary(value) and byte_size(value) <= @max_text_bytes do
    String.valid?(value) and String.trim(value) != ""
  end

  def valid_text?(_value), do: false

  @spec valid_context_text?(term()) :: boolean()
  def valid_context_text?(value)
      when is_binary(value) and byte_size(value) <= @max_text_bytes,
      do: String.valid?(value)

  def valid_context_text?(_value), do: false

  @spec valid_id_list?(term()) :: boolean()
  def valid_id_list?(values), do: bounded_unique_list?(values, @max_references, &valid_id?/1)

  @spec valid_permission_list?(term()) :: boolean()
  def valid_permission_list?(values),
    do: bounded_unique_list?(values, length(@permissions), &permission?/1)

  @spec valid_dispatch_target?(term()) :: boolean()
  def valid_dispatch_target?(:main), do: true
  def valid_dispatch_target?({:reply, id}), do: valid_id?(id)
  def valid_dispatch_target?({:thread, id}), do: valid_id?(id)
  def valid_dispatch_target?({:revise, id}), do: valid_id?(id)

  def valid_dispatch_target?({:chip, kind, id}) when kind in [:command, :goal, :research],
    do: valid_id?(id)

  def valid_dispatch_target?(_target), do: false

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_intent}
  def validate({:dispatch, operation, text, target, attachment_refs} = intent)
      when operation in [:send, :queue] do
    valid_intent(intent, [
      valid_text?(text),
      valid_dispatch_target?(target),
      valid_id_list?(attachment_refs)
    ])
  end

  def validate({:steer, run_id, node_id, text, attachment_refs} = intent) do
    valid_intent(intent, [
      valid_id?(run_id),
      valid_id?(node_id),
      valid_text?(text),
      valid_id_list?(attachment_refs)
    ])
  end

  def validate({:run_control, operation, run_id} = intent)
      when operation in [:pause, :continue, :resume, :stop],
      do: valid_intent(intent, [valid_id?(run_id)])

  def validate({:retry_run, run_id, revision} = intent),
    do: valid_intent(intent, [valid_id?(run_id), non_negative_integer?(revision)])

  def validate({:stop_agent, run_id, agent_id, revision} = intent),
    do:
      valid_intent(intent, [
        valid_id?(run_id),
        valid_id?(agent_id),
        non_negative_integer?(revision)
      ])

  def validate(
        {:answer_question, run_id, node_id, interaction_id, revision, option_ids} = intent
      ),
      do:
        valid_intent(intent, [
          valid_id?(run_id),
          valid_id?(node_id),
          valid_id?(interaction_id),
          non_negative_integer?(revision),
          valid_answer?(option_ids)
        ])

  def validate({:resolve_approval, run_id, node_id, interaction_id, revision, decision} = intent)
      when decision in @decisions,
      do:
        valid_intent(intent, [
          valid_id?(run_id),
          valid_id?(node_id),
          valid_id?(interaction_id),
          non_negative_integer?(revision)
        ])

  def validate({:mark_seen, kind, id, revision} = intent)
      when kind in [:conversation, :run, :activity],
      do: valid_intent(intent, [valid_id?(id), non_negative_integer?(revision)])

  def validate(_intent), do: {:error, :invalid_intent}

  @spec validate!(term()) :: t()
  def validate!(intent) do
    case validate(intent) do
      {:ok, valid} -> valid
      {:error, :invalid_intent} -> raise ArgumentError, "invalid intent"
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(intent), do: match?({:ok, _intent}, validate(intent))

  defp valid_intent(intent, checks) do
    if Enum.all?(checks), do: {:ok, intent}, else: {:error, :invalid_intent}
  end

  defp valid_answer?(%{option_ids: ids, custom_text: custom} = answer) when map_size(answer) == 2,
    do:
      valid_id_list?(ids) and is_binary(custom) and byte_size(custom) <= 4_000 and
        String.valid?(custom) and (ids != [] or String.trim(custom) != "")

  defp valid_answer?(ids), do: valid_id_list?(ids)

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp bounded_unique_list?(values, maximum, validator) when is_list(values) do
    do_bounded_unique_list?(values, maximum, validator, 0, MapSet.new())
  end

  defp bounded_unique_list?(_values, _maximum, _validator), do: false

  defp do_bounded_unique_list?([], _maximum, _validator, _count, _seen), do: true

  defp do_bounded_unique_list?([value | rest], maximum, validator, count, seen)
       when count < maximum do
    if validator.(value) and not MapSet.member?(seen, value) do
      do_bounded_unique_list?(rest, maximum, validator, count + 1, MapSet.put(seen, value))
    else
      false
    end
  end

  defp do_bounded_unique_list?(_values, _maximum, _validator, _count, _seen), do: false

  defp control_free?(<<>>), do: true

  defp control_free?(<<codepoint::utf8, _rest::binary>>)
       when codepoint in 0x00..0x1F or codepoint in 0x7F..0x9F,
       do: false

  defp control_free?(<<_codepoint::utf8, rest::binary>>), do: control_free?(rest)
end
