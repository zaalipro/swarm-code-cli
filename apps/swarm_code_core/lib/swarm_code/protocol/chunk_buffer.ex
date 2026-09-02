defmodule SwarmCode.Protocol.ChunkBuffer do
  @moduledoc """
  A queue-backed byte buffer for incremental protocol input.

  Tiny writes are accumulated as reverse iodata and periodically copied into
  fixed-size owned blocks. The pending fragment list is therefore bounded by
  both a byte target and a fixed fragment count instead of growing with the
  lifetime byte count. `bytes` is the one authoritative total for this buffer;
  decoder compatibility fields are derived from it.
  """

  alias SwarmCode.Protocol.Error

  @block_bytes 4_096
  @max_pending_fragments 64

  defstruct queue: {[], []}, bytes: 0, pending: [], pending_bytes: 0

  @type t :: %__MODULE__{
          queue: :queue.queue(binary()),
          bytes: non_neg_integer(),
          pending: [binary()],
          pending_bytes: non_neg_integer()
        }

  @doc "Build an empty chunk buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{queue: :queue.new()}

  @doc "The fixed byte target used when compacting tiny fragments."
  @spec block_bytes() :: pos_integer()
  def block_bytes, do: @block_bytes

  @doc "Append a binary without concatenating it to previously buffered bytes."
  @spec put(t(), binary()) :: t() | {:error, Error.t()}
  def put(%__MODULE__{} = buffer, binary) when is_binary(binary) do
    if valid_buffer?(buffer) do
      do_put(buffer, binary)
    else
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
    if valid_buffer?(buffer) do
      do_take(buffer, wanted)
    else
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
  def byte_size(%__MODULE__{bytes: bytes}) when is_integer(bytes) and bytes >= 0, do: bytes

  def byte_size(_buffer), do: {:error, Error.new(:invalid_envelope)}

  @doc "Count compacted blocks, treating the bounded pending batch as one block."
  @spec block_count(t()) :: non_neg_integer() | {:error, Error.t()}
  def block_count(%__MODULE__{queue: queue, pending: pending}) when is_list(pending) do
    :queue.len(queue) + if(pending == [], do: 0, else: 1)
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def block_count(_buffer), do: {:error, Error.new(:invalid_envelope)}

  @doc "Count queue cells plus currently bounded pending-fragment cells."
  @spec metadata_nodes(t()) :: non_neg_integer() | {:error, Error.t()}
  def metadata_nodes(%__MODULE__{queue: queue, pending: pending}) when is_list(pending) do
    :queue.len(queue) + length(pending)
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def metadata_nodes(_buffer), do: {:error, Error.new(:invalid_envelope)}

  @doc "Sum the binary storage referenced by retained queue and pending chunks."
  @spec retained_byte_size(t()) :: non_neg_integer() | {:error, Error.t()}
  def retained_byte_size(%__MODULE__{queue: queue, pending: pending}) when is_list(pending) do
    queue
    |> :queue.to_list()
    |> Enum.reduce(pending, fn chunk, chunks -> [chunk | chunks] end)
    |> Enum.reduce(0, fn chunk, total -> :binary.referenced_byte_size(chunk) + total end)
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
    %{buffer | queue: :queue.in(own_sparse_binary(binary), queue)}
  end

  defp append(%__MODULE__{pending_bytes: pending_bytes} = buffer, binary)
       when is_integer(pending_bytes) and pending_bytes >= 0 and pending_bytes < @block_bytes do
    binary = own_sparse_binary(binary)
    available = @block_bytes - pending_bytes

    if Kernel.byte_size(binary) < available do
      next = %{
        buffer
        | pending: [binary | buffer.pending],
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

  defp do_take(buffer, wanted) do
    buffer
    |> flush_pending()
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
            tail = own_sparse_binary(tail)
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

  defp valid_buffer?(%__MODULE__{
         queue: queue,
         bytes: bytes,
         pending: pending,
         pending_bytes: pending_bytes
       })
       when is_integer(bytes) and bytes >= 0 and is_list(pending) and
              is_integer(pending_bytes) and pending_bytes >= 0 and pending_bytes < @block_bytes do
    is_tuple(queue) and tuple_size(queue) == 2 and
      queue_has_valid_shape?(queue) and bytes >= pending_bytes
  end

  defp valid_buffer?(_buffer), do: false

  defp queue_has_valid_shape?(queue) do
    :queue.is_queue(queue)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  # Sub-binaries are retained directly while they still represent a useful
  # fraction of their backing binary. Sparse tails are copied so a few bytes
  # cannot keep a large coalesced socket input alive.
  defp own_sparse_binary(<<>>), do: <<>>

  defp own_sparse_binary(binary) do
    bytes = Kernel.byte_size(binary)
    referenced = :binary.referenced_byte_size(binary)

    if referenced > bytes and (bytes <= @block_bytes or bytes <= div(referenced, 2)) do
      :binary.copy(binary)
    else
      binary
    end
  end
end
