defmodule SwarmCode.Protocol.ServiceHandshake do
  @moduledoc "Closed codecs for the v1 local service handshake."

  alias SwarmCode.Protocol.Error

  @hello_keys ["op", "client", "body_version"]
  @ok_keys [
    "op",
    "body_version",
    "source_epoch",
    "connection_id",
    "capabilities",
    "max_frame_bytes"
  ]
  @capabilities %{
    "query" => :query,
    "detail" => :detail,
    "watch" => :watch,
    "conversation.open" => :conversation_open,
    "conversation.list" => :conversation_list,
    "conversation.new" => :conversation_new,
    "mark_seen" => :mark_seen,
    "project.update" => :project_update,
    "dispatch.send" => :dispatch_send,
    "run.pause" => :run_pause,
    "run.continue" => :run_continue,
    "run.stop" => :run_stop,
    "run.steer" => :run_steer,
    "approval.resolve" => :approval_resolve,
    "feature.command" => :feature_command,
    "question.answer" => :question_answer,
    # pass74 S1-5: settings.query and settings.command (§3.4.1).
    "settings" => :settings
  }
  @max_frame_bytes 1_048_576

  defmodule HelloOk do
    @enforce_keys [:source_epoch, :connection_id, :capabilities, :max_frame_bytes]
    defstruct @enforce_keys

    @type capability ::
            :query
            | :detail
            | :watch
            | :conversation_open
            | :conversation_list
            | :conversation_new
            | :mark_seen
            | :project_update
            | :dispatch_send
            | :run_pause
            | :run_continue
            | :run_stop
            | :run_steer
            | :approval_resolve
            | :feature_command
            | :question_answer
            | :settings

    @type t :: %__MODULE__{
            source_epoch: binary(),
            connection_id: binary(),
            capabilities: [capability()],
            max_frame_bytes: pos_integer()
          }
  end

  @spec hello() :: %{String.t() => term()}
  def hello, do: %{"op" => "hello", "client" => "swarm-code-cli", "body_version" => 1}

  @spec encode_hello() :: {:ok, map()}
  def encode_hello, do: {:ok, hello()}

  @spec decode_hello(term()) :: {:ok, :hello} | {:error, Error.t()}
  def decode_hello(body) when is_map(body) and not is_struct(body) do
    if exact_keys?(body, @hello_keys) and body["op"] === "hello" and
         body["client"] === "swarm-code-cli" and body["body_version"] === 1,
       do: {:ok, :hello},
       else: invalid()
  end

  def decode_hello(_body), do: invalid()

  @spec decode_hello_ok(term()) :: {:ok, HelloOk.t()} | {:error, Error.t()}
  def decode_hello_ok(body) when is_map(body) and not is_struct(body) do
    with true <- exact_keys?(body, @ok_keys),
         true <- body["op"] === "hello_ok" and body["body_version"] === 1,
         true <- uuid?(body["source_epoch"]) and uuid?(body["connection_id"]),
         {:ok, capabilities} <- decode_capabilities(body["capabilities"]),
         true <-
           is_integer(body["max_frame_bytes"]) and
             body["max_frame_bytes"] in 1..@max_frame_bytes do
      {:ok,
       %HelloOk{
         source_epoch: body["source_epoch"],
         connection_id: body["connection_id"],
         capabilities: capabilities,
         max_frame_bytes: body["max_frame_bytes"]
       }}
    else
      _ -> invalid()
    end
  end

  def decode_hello_ok(_body), do: invalid()

  @spec encode_hello_ok(HelloOk.t()) :: {:ok, map()} | {:error, Error.t()}
  def encode_hello_ok(%HelloOk{} = value) do
    if exact_struct_keys?(value, [:source_epoch, :connection_id, :capabilities, :max_frame_bytes]) and
         uuid?(value.source_epoch) and uuid?(value.connection_id) and
         is_integer(value.max_frame_bytes) and value.max_frame_bytes in 1..@max_frame_bytes do
      with {:ok, capabilities} <- encode_capabilities(value.capabilities) do
        {:ok,
         %{
           "op" => "hello_ok",
           "body_version" => 1,
           "source_epoch" => value.source_epoch,
           "connection_id" => value.connection_id,
           "capabilities" => capabilities,
           "max_frame_bytes" => value.max_frame_bytes
         }}
      end
    else
      invalid()
    end
  end

  def encode_hello_ok(_value), do: invalid()

  defp decode_capabilities(values) when is_list(values) and length(values) <= 20 do
    if Enum.uniq(values) == values and Enum.all?(values, &Map.has_key?(@capabilities, &1)) do
      {:ok, Enum.map(values, &Map.fetch!(@capabilities, &1))}
    else
      invalid()
    end
  end

  defp decode_capabilities(_values), do: invalid()

  defp encode_capabilities(values) when is_list(values) and length(values) <= 20 do
    reverse = Map.new(@capabilities, fn {wire, atom} -> {atom, wire} end)

    if Enum.uniq(values) == values and Enum.all?(values, &Map.has_key?(reverse, &1)) do
      {:ok, Enum.map(values, &Map.fetch!(reverse, &1))}
    else
      invalid()
    end
  end

  defp encode_capabilities(_values), do: invalid()

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_struct_keys?(value, fields),
    do: Enum.sort(Map.keys(value)) == Enum.sort([:__struct__ | fields])

  defp uuid?(value) when is_binary(value),
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp uuid?(_value), do: false
  defp invalid, do: {:error, Error.new(:invalid_envelope)}
end
