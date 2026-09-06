defmodule SwarmCodeCLI.UI.DataSource.Fake.Details do
  @moduledoc "Bounded source-owned canonical text; queries never read attachment files."
  alias SwarmCodeCLI.UI.DataSource.{DTO, AdmissionError}
  @max_bytes 4_194_304
  @max_count 32

  def valid?(details) when is_map(details) and not is_struct(details) do
    map_size(details) <= @max_count and
      Enum.all?(details, fn {id, item} ->
        is_map(item) and map_size(item) == 4 and
          match?(%{ref: %DTO.DetailRef{}, text: _, run_id: _, conversation_id: _}, item) and
          DTO.Schema.valid?({:dto, DTO.DetailRef}, item.ref) and item.ref.id == id and
          DTO.Schema.valid?(:id, item.run_id) and DTO.Schema.valid?(:id, item.conversation_id) and
          is_binary(item.text) and String.valid?(item.text) and
          byte_size(item.text) == item.ref.total_bytes
      end) and
      Enum.reduce(details, 0, fn {_, item}, acc -> acc + byte_size(item.text) end) <= @max_bytes
  end

  def valid?(_), do: false

  def store(script, item, text) when byte_size(text) <= 65_536,
    do: {:ok, script, %{item | text: text}}

  def store(script, item, text) do
    ref = %DTO.DetailRef{id: "detail-" <> item.id, total_bytes: byte_size(text)}
    value = %{ref: ref, text: text, run_id: item.run_id, conversation_id: item.conversation_id}
    details = Map.put(script.details, ref.id, value)

    if not Map.has_key?(script.details, ref.id) and valid?(details),
      do:
        {:ok, %{script | details: details}, %{item | text: prefix(text, 4096), detail_ref: ref}},
      else: {:error, :capacity_exceeded}
  end

  def query(script, %{
        kind: {:query_detail, id, offset, limit},
        scope: scope,
        request_id: request_id
      })
      when is_integer(offset) and offset >= 0 and is_integer(limit) and limit in 4..65_536 do
    with %{ref: ref, text: text} = value <- Map.get(script.details, id),
         true <- allowed?(scope, value),
         true <- offset < byte_size(text),
         remaining = binary_part(text, offset, byte_size(text) - offset),
         true <- String.valid?(remaining) do
      chunk = prefix(remaining, limit)
      next = offset + byte_size(chunk)

      DTO.DetailWindow.validate(%DTO.DetailWindow{
        detail_ref: ref,
        offset: offset,
        text: chunk,
        next_offset: if(next == ref.total_bytes, do: nil, else: next),
        through_sequence: script.sequence,
        request_id: request_id
      })
    else
      _ -> {:error, AdmissionError.new(:invalid_origin)}
    end
  end

  def query(_, _), do: {:error, AdmissionError.new(:invalid_request)}

  defp allowed?(%{kind: :global}, _), do: true
  defp allowed?(%{kind: :run, id: id}, %{run_id: id}), do: true
  defp allowed?(%{kind: :conversation, id: id}, %{conversation_id: id}), do: true
  defp allowed?(_, _), do: false

  def prefix(text, bytes) when byte_size(text) <= bytes, do: text

  def prefix(text, bytes) do
    prefix = binary_part(text, 0, bytes)
    if String.valid?(prefix), do: prefix, else: prefix(text, bytes - 1)
  end
end
