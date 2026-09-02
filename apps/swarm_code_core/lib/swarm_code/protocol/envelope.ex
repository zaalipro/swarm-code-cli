defmodule SwarmCode.Protocol.Envelope do
  @moduledoc "Encoding and decoding for the closed v1 JSON message envelope."

  alias SwarmCode.Protocol.{Error, JsonLimits, Message, Scope}

  @outer_keys ~w(v type request_id nonce scope sequence occurred_at body)
  @scope_keys ~w(kind id generation)
  @message_keys [
    :__struct__,
    :version,
    :type,
    :request_id,
    :nonce,
    :scope,
    :sequence,
    :occurred_at,
    :body
  ]
  @scope_struct_keys [:__struct__, :kind, :id, :generation]
  @request_types [:hello, :hello_ok, :request, :response, :error]

  @doc "Encode a typed message as JSON iodata (without a length prefix)."
  @spec encode(Message.t()) :: {:ok, iodata()} | {:error, Error.t()}
  def encode(%Message{} = message) do
    with :ok <- validate_message_struct(message),
         {:ok, type} <- encode_type(message.type),
         :ok <- validate_version(message.version),
         :ok <- validate_request_id(message.request_id),
         :ok <- validate_nonce(message.nonce),
         {:ok, scope} <- encode_scope(message.scope),
         :ok <- validate_sequence(message.sequence),
         :ok <- validate_occurred_at(message.occurred_at),
         :ok <- validate_body_shape(message.body),
         :ok <-
           validate_invariants(
             message.type,
             message.request_id,
             scope,
             message.sequence,
             message.occurred_at
           ),
         document = %{
           "v" => 1,
           "type" => type,
           "request_id" => message.request_id,
           "nonce" => message.nonce,
           "scope" => scope,
           "sequence" => message.sequence,
           "occurred_at" => message.occurred_at,
           "body" => message.body
         },
         :ok <- JsonLimits.validate_term(document),
         {:ok, iodata} <- Jason.encode_to_iodata(document, maps: :strict) do
      {:ok, iodata}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new(:invalid_envelope)}
      _other -> {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def encode(_message), do: {:error, Error.new(:invalid_envelope)}

  @doc "Decode one bounded JSON envelope into a typed message."
  @spec decode(binary()) :: {:ok, Message.t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) do
    case JsonLimits.decode(binary) do
      {:ok, document} -> decode_document(document)
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_json)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_json)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_json)}
  end

  def decode(_binary), do: {:error, Error.new(:invalid_json)}

  defp decode_document(document) when is_map(document) do
    with :ok <- exact_keys(document, @outer_keys),
         {:ok, type} <- decode_type(document["type"]),
         :ok <- validate_version(document["v"]),
         :ok <- validate_request_id(document["request_id"]),
         :ok <- validate_nonce(document["nonce"]),
         {:ok, scope} <- decode_scope(document["scope"]),
         :ok <- validate_sequence(document["sequence"]),
         :ok <- validate_occurred_at(document["occurred_at"]),
         :ok <- validate_body_shape(document["body"]),
         :ok <-
           validate_invariants(
             type,
             document["request_id"],
             scope,
             document["sequence"],
             document["occurred_at"]
           ) do
      {:ok,
       %Message{
         version: 1,
         type: type,
         request_id: document["request_id"],
         nonce: document["nonce"],
         scope: scope,
         sequence: document["sequence"],
         occurred_at: document["occurred_at"],
         body: document["body"]
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_envelope)}
    end
  end

  defp decode_document(_document), do: {:error, Error.new(:invalid_envelope)}

  defp validate_message_struct(%Message{} = message) do
    if Enum.sort(Map.keys(message)) == Enum.sort(@message_keys),
      do: :ok,
      else: {:error, Error.new(:invalid_envelope)}
  end

  defp validate_message_struct(_message), do: {:error, Error.new(:invalid_envelope)}

  defp exact_keys(map, expected) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, Error.new(:invalid_envelope)}
  end

  defp exact_keys(_map, _expected), do: {:error, Error.new(:invalid_envelope)}

  defp decode_type("hello"), do: {:ok, :hello}
  defp decode_type("hello_ok"), do: {:ok, :hello_ok}
  defp decode_type("request"), do: {:ok, :request}
  defp decode_type("response"), do: {:ok, :response}
  defp decode_type("event"), do: {:ok, :event}
  defp decode_type("error"), do: {:ok, :error}
  defp decode_type("snapshot_required"), do: {:ok, :snapshot_required}
  defp decode_type("ping"), do: {:ok, :ping}
  defp decode_type("pong"), do: {:ok, :pong}
  defp decode_type(_unknown), do: {:error, Error.new(:unknown_message_type)}

  defp encode_type(:hello), do: {:ok, "hello"}
  defp encode_type(:hello_ok), do: {:ok, "hello_ok"}
  defp encode_type(:request), do: {:ok, "request"}
  defp encode_type(:response), do: {:ok, "response"}
  defp encode_type(:event), do: {:ok, "event"}
  defp encode_type(:error), do: {:ok, "error"}
  defp encode_type(:snapshot_required), do: {:ok, "snapshot_required"}
  defp encode_type(:ping), do: {:ok, "ping"}
  defp encode_type(:pong), do: {:ok, "pong"}
  defp encode_type(_unknown), do: {:error, Error.new(:unknown_message_type)}

  defp validate_version(1), do: :ok
  defp validate_version(_version), do: {:error, Error.new(:unsupported_protocol_version)}

  defp validate_request_id(nil), do: :ok

  defp validate_request_id(value) when is_binary(value) do
    if canonical_uuid?(value), do: :ok, else: {:error, Error.new(:invalid_envelope)}
  end

  defp validate_request_id(_value), do: {:error, Error.new(:invalid_envelope)}

  defp validate_nonce(value) when is_binary(value) and byte_size(value) == 43 do
    if base64url_chars?(value) do
      case Base.url_decode64(value, padding: false) do
        {:ok, <<_bytes::binary-size(32)>>} -> :ok
        _other -> {:error, Error.new(:invalid_envelope)}
      end
    else
      {:error, Error.new(:invalid_envelope)}
    end
  end

  defp validate_nonce(_value), do: {:error, Error.new(:invalid_envelope)}

  defp base64url_chars?(binary), do: base64url_chars?(binary, 0, byte_size(binary))

  defp base64url_chars?(_binary, index, size) when index == size, do: true

  defp base64url_chars?(binary, index, size) do
    byte = :binary.at(binary, index)

    allowed =
      (byte >= ?A and byte <= ?Z) or (byte >= ?a and byte <= ?z) or
        (byte >= ?0 and byte <= ?9) or byte in [?-, ?_]

    allowed and base64url_chars?(binary, index + 1, size)
  end

  defp decode_scope(nil), do: {:ok, nil}

  defp decode_scope(scope) when is_map(scope) do
    with :ok <- exact_keys(scope, @scope_keys),
         {:ok, kind} <- decode_scope_kind(scope["kind"]),
         :ok <- validate_scope_id(kind, scope["id"]),
         :ok <- validate_nonnegative(scope["generation"]) do
      {:ok, %Scope{kind: kind, id: scope["id"], generation: scope["generation"]}}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_envelope)}
    end
  end

  defp decode_scope(_scope), do: {:error, Error.new(:invalid_envelope)}

  defp encode_scope(nil), do: {:ok, nil}

  defp encode_scope(%Scope{} = scope) do
    with :ok <- validate_scope_struct(scope),
         {:ok, kind} <- encode_scope_kind(scope.kind),
         :ok <- validate_scope_id(scope.kind, scope.id),
         :ok <- validate_nonnegative(scope.generation) do
      {:ok, %{"kind" => kind, "id" => scope.id, "generation" => scope.generation}}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_envelope)}
    end
  end

  defp encode_scope(_scope), do: {:error, Error.new(:invalid_envelope)}

  defp validate_scope_struct(%Scope{} = scope) do
    if Enum.sort(Map.keys(scope)) == Enum.sort(@scope_struct_keys),
      do: :ok,
      else: {:error, Error.new(:invalid_envelope)}
  end

  defp validate_scope_struct(_scope), do: {:error, Error.new(:invalid_envelope)}

  defp decode_scope_kind("global"), do: {:ok, :global}
  defp decode_scope_kind("project"), do: {:ok, :project}
  defp decode_scope_kind("conversation"), do: {:ok, :conversation}
  defp decode_scope_kind("run"), do: {:ok, :run}
  defp decode_scope_kind("research"), do: {:ok, :research}
  defp decode_scope_kind("workflow"), do: {:ok, :workflow}
  defp decode_scope_kind("schedule"), do: {:ok, :schedule}
  defp decode_scope_kind(_unknown), do: {:error, Error.new(:unknown_scope_kind)}

  defp encode_scope_kind(:global), do: {:ok, "global"}
  defp encode_scope_kind(:project), do: {:ok, "project"}
  defp encode_scope_kind(:conversation), do: {:ok, "conversation"}
  defp encode_scope_kind(:run), do: {:ok, "run"}
  defp encode_scope_kind(:research), do: {:ok, "research"}
  defp encode_scope_kind(:workflow), do: {:ok, "workflow"}
  defp encode_scope_kind(:schedule), do: {:ok, "schedule"}
  defp encode_scope_kind(_unknown), do: {:error, Error.new(:unknown_scope_kind)}

  defp validate_scope_id(:global, nil), do: :ok
  defp validate_scope_id(:global, _id), do: {:error, Error.new(:invalid_envelope)}

  defp validate_scope_id(_kind, id) when is_binary(id) do
    if canonical_uuid?(id), do: :ok, else: {:error, Error.new(:invalid_envelope)}
  end

  defp validate_scope_id(_kind, _id), do: {:error, Error.new(:invalid_envelope)}

  defp validate_sequence(nil), do: :ok
  defp validate_sequence(value), do: validate_nonnegative(value)

  defp validate_nonnegative(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_nonnegative(_value), do: {:error, Error.new(:invalid_envelope)}

  defp validate_occurred_at(nil), do: :ok

  defp validate_occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      _other -> {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  end

  defp validate_occurred_at(_value), do: {:error, Error.new(:invalid_envelope)}

  defp validate_invariants(type, request_id, scope, sequence, occurred_at) do
    cond do
      type in @request_types and request_id == nil ->
        {:error, Error.new(:invalid_envelope)}

      type == :event and (scope == nil or sequence == nil or occurred_at == nil) ->
        {:error, Error.new(:invalid_envelope)}

      type == :snapshot_required and scope == nil ->
        {:error, Error.new(:invalid_envelope)}

      true ->
        :ok
    end
  end

  defp validate_body_shape(value) when is_map(value) do
    if is_struct(value),
      do: {:error, Error.new(:invalid_envelope)},
      else: :ok
  end

  defp validate_body_shape(_value), do: {:error, Error.new(:invalid_envelope)}

  defp canonical_uuid?(value) when byte_size(value) == 36 do
    Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)
  rescue
    _exception -> false
  end

  defp canonical_uuid?(_value), do: false
end
