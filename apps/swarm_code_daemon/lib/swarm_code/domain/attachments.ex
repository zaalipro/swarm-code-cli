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

  # spec 74 BUGS-31: 5 MB — the Messages API refuses a larger image, and an
  # image kept in the window was a 400 on every later turn.
  @max_bytes 5_000_000
  @max_per_message 4

  def max_bytes, do: @max_bytes
  def max_per_message, do: @max_per_message

  def dir, do: Workspace.attachments_dir()

  @doc "Writes a base64 (or data-URL) payload to the attachments dir."
  @spec store(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def store(name, mime, data) do
    # spec 74 BUGS-31: the type the browser claimed is only a first filter;
    # the stored extension and MIME come from the bytes. A WebP saved as
    # `.png` was sent as `image/png`, and the provider answered 400 on every
    # later turn while the image stayed in the window.
    with {:ok, _claimed} <- extension(mime),
         :ok <- check_encoded_size(data),
         {:ok, binary} <- decode(data),
         :ok <- check_size(binary),
         {:ok, mime} <- sniff(binary),
         {:ok, ext} <- extension(mime) do
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

  # spec 74 UI-SPEED-16 step 5: the plain decode first (about 33 ms for a
  # 5.9 MB PNG, against 118 ms whitespace-tolerant); a payload with line
  # breaks falls back to the tolerant one.
  defp decode(base64) do
    case Base.decode64(base64) do
      {:ok, binary} ->
        {:ok, binary}

      :error ->
        case Base.decode64(base64, ignore: :whitespace) do
          {:ok, binary} -> {:ok, binary}
          :error -> {:error, "malformed image data"}
        end
    end
  end

  # spec 74 UI-SPEED-16 step 6: a cheap pre-decode refusal of payloads that
  # are clearly too large — the encoded length minus its trailing `=` against
  # `max_bytes/0` in base64 plus 1 KB of slack (the same bound as
  # `WorkspaceLive`'s synchronous check). `check_size/1` after the decode
  # stays the exact guard.
  defp check_encoded_size(data) do
    with {:ok, payload} <- encoded_payload(data) do
      size = byte_size(payload) - trailing_pad(payload)
      if size > div(@max_bytes * 4, 3) + 1024, do: {:error, too_large()}, else: :ok
    else
      :malformed -> :ok
    end
  end

  defp trailing_pad(payload) do
    n = byte_size(payload)

    cond do
      n >= 2 and binary_part(payload, n - 2, 2) == "==" -> 2
      n >= 1 and binary_part(payload, n - 1, 1) == "=" -> 1
      true -> 0
    end
  end

  defp encoded_payload("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [_meta, payload] -> {:ok, payload}
      _ -> :malformed
    end
  end

  defp encoded_payload(data), do: {:ok, data}

  defp check_size(binary) do
    if byte_size(binary) > @max_bytes, do: {:error, too_large()}, else: :ok
  end

  @doc "The refusal `store/3` gives an image over `max_bytes/0` (spec 74 BUGS-31)."
  def too_large, do: "image is larger than #{div(@max_bytes, 1_000_000)} MB"

  @doc """
  spec 74 BUGS-31: the MIME of one of the four supported image types, read from
  the magic bytes — PNG `\\x89PNG`, JPEG `FF D8 FF`, GIF `GIF8`, WebP
  `RIFF....WEBP`.
  """
  @spec sniff(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def sniff(<<0x89, "PNG\r\n", 0x1A, 0x0A, _rest::binary>>), do: {:ok, "image/png"}
  def sniff(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {:ok, "image/jpeg"}
  def sniff(<<"GIF8", _rest::binary>>), do: {:ok, "image/gif"}
  def sniff(<<"RIFF", _size::32, "WEBP", _rest::binary>>), do: {:ok, "image/webp"}
  def sniff(_binary), do: {:error, "not a supported image"}

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
        {:ok, file, ext_mime} <- [path(a["id"])],
        {:ok, binary} <- [File.read(file)] do
      # The MIME comes from the file we actually resolved, not from the row.
      # spec 74 BUGS-31: from its bytes, so a file stored under the wrong
      # extension before the fix is still sent with its real type.
      mime =
        case sniff(binary) do
          {:ok, sniffed} -> sniffed
          {:error, _} -> ext_mime
        end

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

  # pass74 (spec 74) BUGS-32: the provider limits an image block must meet —
  # the Messages API's 5 MB per image (6 990 000 base64 bytes) and 8000 px per side.
  @provider_image_base64_max 6_990_000
  @provider_image_side_max 8000

  @doc """
  pass74 (spec 74) BUGS-32: whether base64 `data` of type `mime` can go to a
  provider as an image block: one of the four supported types, at most
  6 990 000 base64 bytes, valid base64, and — when the header can be read —
  at most 8000 px per side. An image that fails is announced as text instead,
  so one bad screenshot cannot turn every later request into a 400.
  """
  @spec provider_image?(term(), term()) :: boolean()
  def provider_image?(mime, data)
      when is_binary(mime) and is_binary(data) and data != "" and
             byte_size(data) <= @provider_image_base64_max do
    with true <- Map.has_key?(@mimes, mime),
         {:ok, binary} <- Base.decode64(data) do
      case dimensions(binary, mime) do
        {width, height} ->
          width <= @provider_image_side_max and height <= @provider_image_side_max

        nil ->
          true
      end
    else
      _ -> false
    end
  end

  def provider_image?(_mime, _data), do: false

  @doc """
  `{width, height}` read from a PNG, GIF or JPEG header, or nil (WebP, an
  unknown type, a truncated or malformed header).
  """
  @spec dimensions(binary(), term()) :: {non_neg_integer(), non_neg_integer()} | nil
  def dimensions(binary, mime)

  # PNG: the 8-byte signature, then the IHDR chunk — width and height as
  # big-endian 32-bit integers at bytes 16–23.
  def dimensions(
        <<0x89, "PNG\r\n", 0x1A, 0x0A, _len::32, "IHDR", width::32, height::32, _rest::binary>>,
        _mime
      ),
      do: {width, height}

  # GIF: the logical screen descriptor at bytes 6–9, little-endian 16-bit.
  def dimensions(
        <<"GIF8", _version::16, width::little-16, height::little-16, _rest::binary>>,
        _mime
      ),
      do: {width, height}

  # JPEG: walk the marker segments to the frame header.
  def dimensions(<<0xFF, 0xD8, rest::binary>>, _mime), do: jpeg_frame(rest)

  def dimensions(_binary, _mime), do: nil

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

  @doc """
  Deletes old upload files which no persisted message references.

  pass 72 F5 (bugs-4): `opts[:keep]` is an enumerable of attachment ids treated
  like referenced ones — an upload staged for a message not sent yet (the CLI's
  `/attach`) is referenced by no row, and pruning it left the staging pointing
  at a missing file.
  """
  def prune_abandoned(now \\ DateTime.utc_now(), older_than_hours \\ 24, opts \\ []) do
    # spec 68 T17: filter in SQL to skip rows with nil/empty attachments.
    # spec 74 EFFICIENCY-23: the default `[]` rows are skipped in SQL too.
    referenced =
      Repo.all(
        from(m in Message,
          where: not is_nil(m.attachments) and fragment("? != '[]'", m.attachments),
          select: m.attachments
        )
      )
      |> List.flatten()
      |> Enum.map(&Map.get(&1, "id"))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Keyword.get(opts, :keep, [])))

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
