defmodule SwarmCode.Protocol.ChunkBuffer do
  @moduledoc """
  A queue-backed byte buffer for incremental protocol input.

  Tiny writes are accumulated as reverse iodata and periodically copied into
  fixed-size owned blocks. The pending fragment list is therefore bounded by
  both a byte target and a fixed fragment count instead of growing with the
  lifetime byte count. `bytes` is the one authoritative total for this buffer;
  decoder compatibility fields are derived from it. A module-local closure
  retains every canonical state. Public projections are checked against and
  rebuilt from that state, so altered storage cannot become authoritative.
  Ingress owns its backing storage; partial consumption retains a dense view
  and copies only after crossing a half-remaining threshold, which bounds
  cumulative copy work geometrically and prevents sparse-tail amplification.
  Exact canonical values take a constant-time identity fast path; altered
  projections are checked only up to a payload-derived fail-closed scan bound.
  """

  alias SwarmCode.Protocol.Error

  @block_bytes 4_096
  @max_pending_fragments 64
  @default_protocol_frame_bytes 1_048_576
  # The floor is deliberately larger than the canonical 1 MiB frame's
  # ceil(bytes / block_bytes) + pending-fragment allowance. Larger custom
  # decoder limits use the same formula at validation time, so work stays
  # finite and proportional rather than becoming an unbounded scan.
  @minimum_validation_chunks max(
                               1_024,
                               div(@default_protocol_frame_bytes + @block_bytes - 1, @block_bytes) +
                                 @max_pending_fragments
                             )

  defstruct queue: {[], []}, bytes: 0, pending: [], pending_bytes: 0, seal: nil

  @type t :: %__MODULE__{
          queue: :queue.queue(binary()),
          bytes: non_neg_integer(),
          pending: [binary()],
          pending_bytes: non_neg_integer(),
          seal: term()
        }

  @doc "Build an empty chunk buffer."
  @spec new() :: t()
  def new, do: seal_buffer(%__MODULE__{queue: :queue.new()})

  @doc "The fixed byte target used when compacting tiny fragments."
  @spec block_bytes() :: pos_integer()
  def block_bytes, do: @block_bytes

  @doc "Append a binary without concatenating it to previously buffered bytes."
  @spec put(t(), binary()) :: t() | {:error, Error.t()}
  def put(%__MODULE__{} = buffer, binary) when is_binary(binary) do
    case canonical_buffer(buffer) do
      {:ok, canonical} ->
        case do_put(canonical, binary) do
          %__MODULE__{} = next -> seal_buffer(next)
          other -> other
        end

      :error ->
        {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def put(_buffer, _binary), do: {:error, Error.new(:invalid_envelope)}

  @doc "Take exactly `wanted` bytes as iodata, or return `:more`."
  @spec take(t(), non_neg_integer()) :: {:ok, iodata(), t()} | :more | {:error, Error.t()}
  def take(%__MODULE__{} = buffer, wanted) when is_integer(wanted) and wanted >= 0 do
    case canonical_buffer(buffer) do
      {:ok, canonical} ->
        case do_take(canonical, wanted) do
          {:ok, parts, %__MODULE__{} = next} -> {:ok, parts, seal_buffer(next)}
          other -> other
        end

      :error ->
        {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def take(_buffer, _wanted), do: {:error, Error.new(:invalid_envelope)}

  @doc "Return the authoritative number of bytes currently buffered."
  @spec byte_size(t()) :: non_neg_integer() | {:error, Error.t()}
  def byte_size(%__MODULE__{} = buffer) do
    case canonical_buffer(buffer) do
      {:ok, canonical} -> canonical.bytes
      :error -> {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def byte_size(_buffer), do: {:error, Error.new(:invalid_envelope)}

  @doc "Validate the canonical public buffer representation without changing it."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = buffer) do
    case canonical_buffer(buffer) do
      {:ok, _canonical} -> :ok
      :error -> {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def validate(_buffer), do: {:error, Error.new(:invalid_envelope)}

  @doc "Count compacted blocks, treating the bounded pending batch as one block."
  @spec block_count(t()) :: non_neg_integer() | {:error, Error.t()}
  def block_count(%__MODULE__{} = buffer) do
    case canonical_buffer(buffer) do
      {:ok, canonical} ->
        :queue.len(canonical.queue) + if(canonical.pending == [], do: 0, else: 1)

      :error ->
        {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def block_count(_buffer), do: {:error, Error.new(:invalid_envelope)}

  @doc "Count queue cells plus currently bounded pending-fragment cells."
  @spec metadata_nodes(t()) :: non_neg_integer() | {:error, Error.t()}
  def metadata_nodes(%__MODULE__{} = buffer) do
    case canonical_buffer(buffer) do
      {:ok, canonical} -> :queue.len(canonical.queue) + length(canonical.pending)
      :error -> {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def metadata_nodes(_buffer), do: {:error, Error.new(:invalid_envelope)}

  @doc "Sum the binary storage referenced by retained queue and pending chunks."
  @spec retained_byte_size(t()) :: non_neg_integer() | {:error, Error.t()}
  def retained_byte_size(%__MODULE__{} = buffer) do
    case canonical_buffer(buffer) do
      {:ok, canonical} ->
        canonical.queue
        |> :queue.to_list()
        |> Enum.reduce(canonical.pending, fn chunk, chunks -> [chunk | chunks] end)
        |> Enum.reduce(0, fn chunk, total -> :binary.referenced_byte_size(chunk) + total end)

      :error ->
        {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def retained_byte_size(_buffer), do: {:error, Error.new(:invalid_envelope)}

  defp do_put(buffer, <<>>), do: buffer

  defp do_put(%__MODULE__{bytes: bytes} = buffer, binary) do
    buffer
    |> Map.put(:bytes, bytes + Kernel.byte_size(binary))
    |> append(binary)
  end

  defp append(buffer, <<>>), do: buffer

  defp append(%__MODULE__{pending_bytes: 0, queue: queue} = buffer, binary)
       when Kernel.byte_size(binary) >= @block_bytes do
    %{buffer | queue: :queue.in(own_binary(binary), queue)}
  end

  defp append(%__MODULE__{pending_bytes: pending_bytes} = buffer, binary)
       when is_integer(pending_bytes) and pending_bytes >= 0 and pending_bytes < @block_bytes do
    available = @block_bytes - pending_bytes

    if Kernel.byte_size(binary) < available do
      next = %{
        buffer
        | pending: [own_binary(binary) | buffer.pending],
          pending_bytes: pending_bytes + Kernel.byte_size(binary)
      }

      if length(next.pending) >= @max_pending_fragments,
        do: compact_pending(next),
        else: next
    else
      <<head::binary-size(available), tail::binary>> = binary
      block = IO.iodata_to_binary([Enum.reverse(buffer.pending), head])

      buffer
      |> Map.put(:queue, :queue.in(block, buffer.queue))
      |> Map.put(:pending, [])
      |> Map.put(:pending_bytes, 0)
      |> append(tail)
    end
  end

  defp do_take(buffer, 0), do: {:ok, [], buffer}

  defp do_take(%__MODULE__{bytes: available}, wanted) when wanted > available, do: :more

  defp do_take(%__MODULE__{bytes: available, pending_bytes: pending_bytes} = buffer, wanted) do
    # Pending bytes arrive after the queue. Keep them as pending when the
    # queue alone satisfies this take; flushing a one-byte pending fragment
    # on every small take would otherwise create one queue cell per call.
    queue_bytes = available - pending_bytes
    buffer = if wanted > queue_bytes, do: flush_pending(buffer), else: buffer

    buffer
    |> take_queue(wanted, [])
    |> case do
      {:ok, parts, next} -> {:ok, parts, %{next | bytes: buffer.bytes - wanted}}
      :more -> :more
      other -> other
    end
  end

  defp take_queue(%__MODULE__{queue: queue} = buffer, wanted, parts) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        :more

      {{:value, chunk}, rest} ->
        chunk_bytes = Kernel.byte_size(chunk)

        cond do
          chunk_bytes < wanted ->
            take_queue(%{buffer | queue: rest}, wanted - chunk_bytes, [chunk | parts])

          chunk_bytes == wanted ->
            {:ok, Enum.reverse([chunk | parts]), %{buffer | queue: rest}}

          true ->
            <<head::binary-size(wanted), tail::binary>> = chunk
            tail = retain_tail(tail)
            queue = :queue.in_r(tail, rest)
            {:ok, Enum.reverse([head | parts]), %{buffer | queue: queue}}
        end
    end
  end

  defp flush_pending(%__MODULE__{pending: []} = buffer), do: buffer

  defp flush_pending(%__MODULE__{queue: queue, pending: pending} = buffer) do
    block = pending |> Enum.reverse() |> IO.iodata_to_binary()
    %{buffer | queue: :queue.in(block, queue), pending: [], pending_bytes: 0}
  end

  defp compact_pending(%__MODULE__{pending: pending} = buffer) do
    block = pending |> Enum.reverse() |> IO.iodata_to_binary()
    %{buffer | pending: [block]}
  end

  defp canonical_buffer(
         %__MODULE__{
           queue: queue,
           bytes: bytes,
           pending: pending,
           pending_bytes: pending_bytes,
           seal: seal
         } = buffer
       )
       when is_integer(bytes) and bytes >= 0 and
              is_integer(pending_bytes) and pending_bytes >= 0 and pending_bytes < @block_bytes do
    cond do
      map_size(buffer) != 6 ->
        :error

      is_nil(seal) ->
        if exact_unsealed_empty?(queue, pending, bytes, pending_bytes),
          do: {:ok, buffer},
          else: :error

      true ->
        with {:ok, canonical} <- sealed_buffer(seal),
             true <- bytes === canonical.bytes,
             true <- pending_bytes === canonical.pending_bytes,
             scan_limit = validation_chunk_limit(canonical.bytes),
             {:ok, scanned} <- validate_queue_projection(queue, canonical.queue, scan_limit),
             :ok <-
               validate_pending_projection(pending, canonical.pending, scan_limit - scanned) do
          {:ok, canonical}
        else
          _other -> :error
        end
    end
  end

  defp canonical_buffer(_buffer), do: :error

  defp exact_unsealed_empty?({[], []}, [], 0, 0), do: true
  defp exact_unsealed_empty?(_queue, _pending, _bytes, _pending_bytes), do: false

  defp sealed_buffer(seal) when is_function(seal, 0) do
    with {:module, __MODULE__} <- :erlang.fun_info(seal, :module),
         {:type, :local} <- :erlang.fun_info(seal, :type),
         {:chunk_buffer_state, queue, bytes, pending, pending_bytes} <- seal.(),
         true <- is_integer(bytes) and bytes >= 0,
         true <- is_integer(pending_bytes) and pending_bytes >= 0,
         true <- pending_bytes < @block_bytes do
      {:ok,
       %__MODULE__{
         queue: queue,
         bytes: bytes,
         pending: pending,
         pending_bytes: pending_bytes,
         seal: seal
       }}
    else
      _other -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp sealed_buffer(_seal), do: :error

  defp validate_queue_projection(candidate, canonical, scan_limit) do
    if same_term?(candidate, canonical) do
      {:ok, 0}
    else
      validate_queue_chunks(candidate, canonical, scan_limit)
    end
  end

  defp validate_queue_chunks(
         {candidate_rear, candidate_front},
         {canonical_rear, canonical_front},
         limit
       ) do
    with {:ok, count} <-
           matching_retained_chunks(
             candidate_rear,
             canonical_rear,
             0,
             limit
           ),
         {:ok, final_count} <-
           matching_retained_chunks(
             candidate_front,
             canonical_front,
             count,
             limit
           ) do
      {:ok, final_count}
    else
      _other -> :error
    end
  end

  defp validate_queue_chunks(_candidate, _canonical, _limit), do: :error

  defp validation_chunk_limit(bytes) do
    payload_chunks = div(bytes + @block_bytes - 1, @block_bytes)
    max(@minimum_validation_chunks, payload_chunks + @max_pending_fragments)
  end

  defp validate_pending_projection(candidate, canonical, remaining) when remaining >= 0 do
    if same_term?(candidate, canonical) do
      :ok
    else
      limit = min(remaining, @max_pending_fragments)

      case matching_retained_chunks(candidate, canonical, 0, limit) do
        {:ok, _count} -> :ok
        :error -> :error
      end
    end
  end

  defp validate_pending_projection(_candidate, _canonical, _remaining), do: :error

  defp matching_retained_chunks([], [], count, _limit), do: {:ok, count}

  defp matching_retained_chunks(
         [candidate | candidate_rest],
         [canonical | canonical_rest],
         count,
         limit
       )
       when count < limit do
    if matching_retained_binary?(candidate, canonical) do
      matching_retained_chunks(candidate_rest, canonical_rest, count + 1, limit)
    else
      :error
    end
  end

  defp matching_retained_chunks(_candidate, _canonical, _count, _limit), do: :error

  defp matching_retained_binary?(candidate, canonical)
       when is_binary(candidate) and is_binary(canonical) and
              Kernel.byte_size(candidate) > 0 do
    candidate_bytes = Kernel.byte_size(candidate)
    candidate_referenced = :binary.referenced_byte_size(candidate)
    canonical_referenced = :binary.referenced_byte_size(canonical)

    candidate_bytes == Kernel.byte_size(canonical) and
      candidate_referenced <= canonical_referenced and
      bounded_retained_binary?(candidate_bytes, candidate_referenced) and
      candidate === canonical
  end

  defp matching_retained_binary?(_candidate, _canonical), do: false

  defp bounded_retained_binary?(bytes, referenced) do
    referenced >= bytes and
      (referenced == bytes or bytes > div(referenced, 2))
  end

  # This OTP-pinned identity check is only the normal-state fast path. On a
  # mismatch, the public ownership API above enforces the storage invariant.
  # Operations always rebuild from the canonical closure state either way.
  defp same_term?(left, right) do
    :erts_debug.same(left, right)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp seal_buffer(%__MODULE__{} = buffer) do
    queue = buffer.queue
    pending = buffer.pending
    bytes = buffer.bytes
    pending_bytes = buffer.pending_bytes

    %{
      buffer
      | seal: fn ->
          {:chunk_buffer_state, queue, bytes, pending, pending_bytes}
        end
    }
  end

  # Ingress is copied once when it is a view into caller-owned storage.
  defp own_binary(<<>>), do: <<>>

  defp own_binary(binary) do
    bytes = Kernel.byte_size(binary)
    referenced = :binary.referenced_byte_size(binary)

    if referenced == bytes, do: binary, else: :binary.copy(binary)
  end

  # Partial consumption keeps a dense view over storage already owned by the
  # buffer. Once no more than half remains, a single copy releases the old
  # backing and resets the threshold. Successive copies therefore form a
  # geometric series bounded by the original input size, and any retained tail
  # references less than twice its logical size.
  defp retain_tail(binary) do
    bytes = Kernel.byte_size(binary)
    referenced = :binary.referenced_byte_size(binary)

    if referenced > bytes and bytes <= div(referenced, 2),
      do: :binary.copy(binary),
      else: binary
  end
end
