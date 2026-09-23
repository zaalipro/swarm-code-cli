defmodule SwarmCode.Domain.Attachments do
  @moduledoc """
  Images pasted or dropped into the composer.

  Files live under `Workspace.attachments_dir/0`; messages only store
  `%{"id", "name", "mime", "path"}`.
  """

  alias SwarmCode.Domain.AtomicFile
  alias SwarmCode.Domain.Projects.Workspace
  alias SwarmCode.Domain.{Conversations.Message, Repo}
  import Ecto.Query
  require Logger

  @mimes %{
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp"
  }

  @max_bytes 6_000_000
  @max_per_message 4

  def max_bytes, do: @max_bytes
  def max_per_message, do: @max_per_message

  def dir, do: Workspace.attachments_dir()

  @doc "Writes a base64 (or data-URL) payload to the attachments dir."
  @spec store(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def store(name, mime, data) do
    with {:ok, ext} <- extension(mime),
         :ok <- check_encoded_size(data),
         {:ok, binary} <- decode(data),
         :ok <- check_size(binary) do
      id = Ecto.UUID.generate()
      File.mkdir_p(dir())
      path = Path.join(dir(), id <> "." <> ext)

      # Spec 32 §3: the bytes land whole or not at all, and `path`/`mime` are
      # written for the record only — every read resolves from `id`.
      case AtomicFile.replace(dir(), path, binary) do
        :ok ->
          {:ok,
           %{
             "id" => id,
             "name" => clean_name(name, ext),
             "mime" => mime,
             "path" => path
           }}

        {:error, reason} ->
          {:error, "cannot save the image: #{AtomicFile.format_error(reason)}"}
      end
    end
  end

  defp extension(mime) do
    case Map.fetch(@mimes, mime) do
      {:ok, ext} -> {:ok, ext}
      :error -> {:error, "unsupported image type #{mime}"}
    end
  end

  defp decode("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [_meta, payload] -> decode(payload)
      _ -> {:error, "malformed image data"}
    end
  end

  defp decode(base64) do
    case Base.decode64(base64, ignore: :whitespace) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, "malformed image data"}
    end
  end

  defp check_encoded_size(data) do
    with {:ok, payload} <- encoded_payload(data) do
      {length, previous, last} = base64_shape(payload, 0, nil, nil)

      padding =
        cond do
          previous == ?= and last == ?= -> 2
          last == ?= -> 1
          true -> 0
        end

      minimum = max(div(length * 3, 4) - padding, 0)
      if minimum > @max_bytes, do: {:error, "image is larger than 6 MB"}, else: :ok
    else
      :malformed -> :ok
    end
  end

  defp base64_shape(<<>>, length, previous, last), do: {length, previous, last}

  defp base64_shape(<<byte, rest::binary>>, length, previous, last)
       when byte in [9, 10, 13, 32],
       do: base64_shape(rest, length, previous, last)

  defp base64_shape(<<byte, rest::binary>>, length, _previous, last),
    do: base64_shape(rest, length + 1, last, byte)

  defp encoded_payload("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [_meta, payload] -> {:ok, payload}
      _ -> :malformed
    end
  end

  defp encoded_payload(data), do: {:ok, data}

  defp check_size(binary) do
    if byte_size(binary) > @max_bytes, do: {:error, "image is larger than 6 MB"}, else: :ok
  end

  defp clean_name(name, ext) do
    name = name |> to_string() |> Path.basename() |> String.slice(0, 80)
    if name == "", do: "image." <> ext, else: name
  end

  @doc """
  The absolute path and MIME of an attachment id.

  Spec 32 §3: everything is derived from the id — a canonical UUID and one of
  the four allowed extensions. The stored `path` and `mime` are never trusted,
  and a UUID-named symlink is not an attachment: only a regular file whose real
  path is still inside the attachments directory answers.
  """
  @spec path(String.t()) :: {:ok, String.t(), String.t()} | :error
  def path(id) do
    with {:ok, id} <- canonical_id(id),
         {file, mime} when is_binary(file) <- resolve(id) do
      {:ok, file, mime}
    else
      _other -> :error
    end
  end

  defp canonical_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp canonical_id(_id), do: :error

  defp valid_id?(id), do: match?({:ok, _uuid}, canonical_id(id))

  defp resolve(id) do
    root = dir()

    Enum.find_value(@mimes, fn {mime, ext} ->
      candidate = Path.join(root, id <> "." <> ext)
      if regular_and_inside?(root, candidate), do: {candidate, mime}
    end)
  end

  defp regular_and_inside?(root, candidate) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(candidate)) and
      SwarmCode.Domain.Tools.Path.confined?(root, candidate)
  end

  @doc """
  The base64 payload of an attachment, for the multimodal request.

  By id: a forged `path` in the persisted metadata reads nothing.
  """
  @spec read_base64(map()) :: {:ok, String.t()} | :error
  def read_base64(%{"id" => id}) do
    with {:ok, file, _mime} <- path(id),
         {:ok, binary} <- File.read(file) do
      {:ok, Base.encode64(binary)}
    else
      _other -> :error
    end
  end

  def read_base64(_), do: :error

  @doc "The `%{mime, data, tokens}` images of a message's attachment list."
  @spec images([map()]) :: [map()]
  def images(attachments) do
    for a <- attachments || [],
        {:ok, file, mime} <- [path(a["id"])],
        {:ok, binary} <- [File.read(file)] do
      # The MIME comes from the file we actually resolved, not from the row.
      %{
        mime: mime,
        data: Base.encode64(binary),
        name: a["name"],
        # Spec 51 §6.5: what the image will actually cost, so the context
        # estimate stops charging a 1.5 MB screenshot half a million tokens.
        tokens: image_tokens(binary, mime)
      }
    end
  end

  @doc """
  The total size in bytes of an attachment list, resolved from the files
  (spec 51 §6.5). An attachment whose file is gone counts nothing.
  """
  @spec size([map()]) :: non_neg_integer()
  def size(attachments) do
    Enum.reduce(attachments || [], 0, fn a, total ->
      with {:ok, file, _mime} <- path(a["id"]),
           {:ok, %File.Stat{size: bytes}} <- File.stat(file) do
        total + bytes
      else
        _other -> total
      end
    end)
  end

  # Spec 51 §6.5: Anthropic and every OpenAI-compatible server charge an image
  # by its area — `ceil(w / 28) * ceil(h / 28)` tokens, capped at 4 784 (the
  # 1568 × 1568 ceiling both document). The old estimate charged
  # `base64_bytes / 4`, which made one 1.5 MB PNG worth 500 781 tokens and
  # evicted the whole history behind it.
  @image_token_cap 4_784
  @patch 28

  @doc "The token cost of an image, read from its header (spec 51 §6.5)."
  @spec image_tokens(binary(), String.t()) :: pos_integer()
  def image_tokens(binary, mime) when is_binary(binary) do
    case dimensions(binary, mime) do
      {width, height} when width > 0 and height > 0 ->
        min(ceil(width / @patch) * ceil(height / @patch), @image_token_cap)

      # WebP, an unknown MIME, a truncated or malformed header: charge the cap,
      # which is what a full-size screenshot costs anyway.
      _other ->
        @image_token_cap
    end
  end

  def image_tokens(_binary, _mime), do: @image_token_cap

  @doc "The cap an image whose header cannot be read is charged (spec 51 §6.5)."
  def image_token_cap, do: @image_token_cap

  # PNG: the 8-byte signature, then the IHDR chunk — width and height as
  # big-endian 32-bit integers at bytes 16–23.
  defp dimensions(
         <<0x89, "PNG\r\n", 0x1A, 0x0A, _len::32, "IHDR", width::32, height::32, _rest::binary>>,
         _mime
       ),
       do: {width, height}

  # GIF: the logical screen descriptor at bytes 6–9, little-endian 16-bit.
  defp dimensions(
         <<"GIF8", _version::16, width::little-16, height::little-16, _rest::binary>>,
         _mime
       ),
       do: {width, height}

  # JPEG: walk the marker segments to the frame header.
  defp dimensions(<<0xFF, 0xD8, rest::binary>>, _mime), do: jpeg_frame(rest)

  defp dimensions(_binary, _mime), do: nil

  # SOF0 (baseline) / SOF1 / SOF2 (progressive) / SOF3 carry the frame size:
  # marker, length, precision, then height and width at offsets 5–8 of the
  # segment. Every other segment is skipped by its own length.
  defp jpeg_frame(<<0xFF, marker, _len::16, _precision, height::16, width::16, _rest::binary>>)
       when marker in [0xC0, 0xC1, 0xC2, 0xC3],
       do: {width, height}

  defp jpeg_frame(<<0xFF, 0xFF, rest::binary>>), do: jpeg_frame(<<0xFF, rest::binary>>)

  # Standalone markers (RSTn, SOI, EOI, TEM) carry no length.
  defp jpeg_frame(<<0xFF, marker, rest::binary>>)
       when marker in 0xD0..0xD9 or marker == 0x01,
       do: jpeg_frame(rest)

  defp jpeg_frame(<<0xFF, _marker, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    if byte_size(rest) > skip,
      do: jpeg_frame(binary_part(rest, skip, byte_size(rest) - skip)),
      else: nil
  end

  defp jpeg_frame(_binary), do: nil

  def delete(id) do
    case path(id) do
      {:ok, file, _mime} -> File.rm(file)
      :error -> :ok
    end
  end

  @doc "Deletes old upload files which no persisted message references."
  def prune_abandoned(now \\ DateTime.utc_now(), older_than_hours \\ 24) do
    # spec 68 T17: filter in SQL to skip rows with nil/empty attachments.
    referenced =
      Repo.all(
        from(m in Message,
          where: not is_nil(m.attachments),
          select: m.attachments
        )
      )
      |> List.flatten()
      |> Enum.map(&Map.get(&1, "id"))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    cutoff = DateTime.to_unix(now) - older_than_hours * 3_600

    case File.ls(dir()) do
      {:ok, files} ->
        deleted =
          Enum.reduce(files, 0, fn file, count ->
            id = Path.rootname(file)
            path = Path.join(dir(), file)

            cond do
              not valid_id?(id) ->
                Logger.warning("Ignoring unexpected attachment filename #{inspect(file)}")
                count

              MapSet.member?(referenced, id) ->
                count

              old_file?(path, cutoff) ->
                case File.rm(path) do
                  :ok ->
                    count + 1

                  {:error, reason} ->
                    Logger.warning("Could not prune attachment #{id}: #{inspect(reason)}")
                    count
                end

              true ->
                count
            end
          end)

        {:ok, deleted}

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp old_file?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime < cutoff
      _ -> false
    end
  end
end
