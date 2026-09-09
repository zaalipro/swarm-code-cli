defmodule SyncUnicodeWidth do
  import Bitwise
  @root Path.expand("../..", __DIR__)
  @vendor Path.join(@root, "third_party/unicode-width-0.2.2")
  @upstream Path.join(@vendor, "UPSTREAM.json")
  @files [
    "COPYRIGHT",
    "LICENSE-MIT",
    "LICENSE-APACHE",
    "src/lib.rs",
    "src/tables.rs",
    "tests/emoji-test.txt"
  ]

  def main(args) do
    case args do
      ["--check"] ->
        check!()

      ["--accept", archive] ->
        accept!(archive)

      _ ->
        IO.puts(:stderr, "usage: sync_unicode_width.exs --check | --accept SOURCE_CRATE") &&
          System.halt(2)
    end
  end

  defp accept!(archive) do
    expected = metadata!()["source_sha256"]
    bytes = File.read!(archive)
    if sha(bytes) != expected, do: fail!("source checksum mismatch")
    {:ok, entries} = :erl_tar.table({:binary, bytes}, [:compressed, :verbose])
    Enum.each(entries, &validate_entry!/1)
    tmp = Path.join(System.tmp_dir!(), "unicode-width-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      :ok = :erl_tar.extract({:binary, bytes}, [:compressed, {:cwd, String.to_charlist(tmp)}])
      root = Path.join(tmp, "unicode-width-0.2.2")

      Enum.each(@files, fn rel ->
        src = Path.join(root, rel)
        dest = Path.join(@vendor, rel)
        File.mkdir_p!(Path.dirname(dest))
        atomic_copy!(src, dest)
      end)

      generate_table!()
      generate_vectors!()
      check!()
    after
      File.rm_rf(tmp)
    end
  end

  defp validate_entry!({entry, type, _size, _mtime, _mode, _uid, _gid}) do
    path = List.to_string(entry)

    if String.starts_with?(path, "/") or Enum.any?(Path.split(path), &(&1 == "..")),
      do: fail!("unsafe archive entry: #{path}")

    if String.contains?(path, "\\"), do: fail!("unsafe archive entry: #{path}")

    unless type in [:regular, :directory],
      do: fail!("unsupported archive entry type #{inspect(type)}: #{path}")
  end

  defp check! do
    meta = metadata!()

    Enum.each(meta["files"], fn {rel, expected} ->
      verify_hash!(Path.join(@vendor, rel), expected)
    end)

    Enum.each(meta["generated"], fn {rel, expected} ->
      verify_hash!(Path.join(@root, rel), expected)
    end)

    IO.puts("unicode-width 0.2.2 attestation OK")
  end

  defp verify_hash!(path, expected) do
    unless File.regular?(path) and sha(File.read!(path)) == expected,
      do: fail!("hash mismatch: #{path}")
  end

  defp atomic_copy!(src, dest) do
    tmp = dest <> ".tmp-#{System.unique_integer([:positive])}"
    File.cp!(src, tmp)
    File.rename!(tmp, dest)
  end

  defp generate_table! do
    source = File.read!(Path.join(@vendor, "src/tables.rs"))
    root = static_bytes!(source, "WIDTH_ROOT", "WIDTH_ROOT_CJK")
    root_cjk = static_bytes!(source, "WIDTH_ROOT_CJK", "WIDTH_MIDDLE")
    middle = static_bytes!(source, "WIDTH_MIDDLE", "WIDTH_LEAVES")
    leaves = static_bytes!(source, "WIDTH_LEAVES", "NON_TRANSPARENT_ZERO_WIDTHS")

    unless {length(root), length(root_cjk), length(middle), length(leaves)} ==
             {256, 256, 1280, 5952},
           do: fail!("unexpected Rust table layout")

    narrow = width_ranges(root, middle, leaves)
    wide = width_ranges(root_cjk, middle, leaves)
    emoji_presentation = emoji_presentation_ranges(source)
    text_presentation = prefixed_ranges(source, "TEXT_PRESENTATION_LEAF", [0x23, 0x25, 0x26, 0x27, 0x2B, 0x1F0, 0x1F3, 0x1F4, 0x1F5, 0x1F6])
    emoji_modifier = prefixed_ranges(source, "EMOJI_MODIFIER_LEAF", [0x26, 0x27, 0x1F3, 0x1F4, 0x1F5, 0x1F6, 0x1F9, 0x1FA])
    non_transparent = triplet_ranges(source, "NON_TRANSPARENT_ZERO_WIDTHS")
    solidus_transparent = triplet_ranges(source, "SOLIDUS_TRANSPARENT")

    body = """
    defmodule SwarmCodeCLI.UI.Width.Table do
      @moduledoc "Unicode 17.0.0 width tables generated from unicode-width 0.2.2."
      @narrow [
    #{render_ranges(narrow)}
      ]
      @wide [
    #{render_ranges(wide)}
      ]
      @emoji_presentation [
    #{render_plain_ranges(emoji_presentation)}
      ]
      @text_presentation [
    #{render_plain_ranges(text_presentation)}
      ]
      @emoji_modifier_base [
    #{render_plain_ranges(emoji_modifier)}
      ]
      @non_transparent_zero_width [
    #{render_plain_ranges(non_transparent)}
      ]
      @solidus_transparent [
    #{render_plain_ranges(solidus_transparent)}
      ]

      @narrow_tuple List.to_tuple(@narrow)
      @wide_tuple List.to_tuple(@wide)

      def width(cp, mode), do: elem(width_info(cp, mode), 0)

      def width_info(cp, mode) when mode in [:narrow, :wide] do
        raw = lookup(if(mode == :narrow, do: @narrow_tuple, else: @wide_tuple), cp)

        if cp == 0x2764 and mode == :wide do
          {2, 0}
        else
          if raw < 3 do
          {raw, 0}
          else
            special_info(cp, mode)
          end
        end
      end

      def starts_emoji_presentation_seq?(cp), do: member?(@emoji_presentation, cp)
      def starts_non_ideographic_text_presentation_seq?(cp), do: member?(@text_presentation, cp)
      def emoji_modifier_base?(cp), do: member?(@emoji_modifier_base, cp)

      def ligature_transparent?(cp),
        do:
          cp in [0x34F, 0x180F, 0x200D] or cp in 0x17B4..0x17B5 or
            cp in 0x180B..0x180D or cp in 0xFE00..0xFE0F or cp in 0xE0100..0xE01EF

      def transparent_zero_width?(cp),
        do: width(cp, :narrow) == 0 and not member?(@non_transparent_zero_width, cp)

      def solidus_transparent?(cp),
        do: ligature_transparent?(cp) or member?(@solidus_transparent, cp)

      defp lookup(ranges, cp), do: lookup(ranges, cp, 0, tuple_size(ranges) - 1)
      defp lookup(_ranges, _cp, low, high) when low > high, do: 1

      defp lookup(ranges, cp, low, high) do
        middle = div(low + high, 2)
        {lo, hi, width} = elem(ranges, middle)

        cond do
          cp < lo -> lookup(ranges, cp, low, middle - 1)
          cp > hi -> lookup(ranges, cp, middle + 1, high)
          true -> width
        end
      end

      defp special_info(0xA, _), do: {1, 1}
      defp special_info(0x338, :wide), do: {0, 0x3CFF}
      defp special_info(0x5DC, _), do: {1, 0x3800}
      defp special_info(cp, _) when cp in 0x622..0x882, do: {1, 0x30FF}
      defp special_info(cp, _) when cp in 0x1780..0x17AF, do: {1, 0x3C07}
      defp special_info(0x17D8, _), do: {3, 0}
      defp special_info(0x1A10, _), do: {1, 0x3801}
      defp special_info(cp, _) when cp in 0x2D31..0x2D6F, do: {1, 0x3803}
      defp special_info(cp, _) when cp in 0xA4FC..0xA4FD, do: {1, 0x3C05}
      defp special_info(0xFE01, :narrow), do: {0, 0x200}
      defp special_info(cp, :wide) when cp in 0xFE00..0xFE02, do: {0, 0x200}
      defp special_info(0xFE0E, :narrow), do: {0, 0x4000}
      defp special_info(0xFE0F, _), do: {0, 0x8000}
      defp special_info(0x10C03, _), do: {1, 0x3806}
      defp special_info(0x16D67, _), do: {1, 0x20}
      defp special_info(0x16D68, _), do: {1, 0x21}
      defp special_info(cp, _) when cp in 0x1F1E6..0x1F1FF, do: {1, 3}
      defp special_info(cp, _) when cp in 0x1F3FB..0x1F3FF, do: {2, 2}
      defp special_info(_cp, _mode), do: {2, 5}

      defp member?(ranges, cp), do: Enum.any?(ranges, fn {lo, hi} -> cp >= lo and cp <= hi end)
    end
    """

    formatted = body |> String.trim_leading() |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")

    atomic_write!(
      Path.join(@root, "apps/swarm_code_cli/lib/swarm_code_cli/ui/width/table.ex"),
      formatted
    )
  end

  defp static_bytes!(source, name, following) do
    [_before, rest] = String.split(source, "static #{name}:", parts: 2)
    [block, _after] = String.split(rest, "static #{following}:", parts: 2)

    Regex.scan(~r/0x([0-9A-Fa-f]+)/, block, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.to_integer(&1, 16))
  end

  defp width_ranges(root, middle, leaves) do
    values =
      for cp <- 0..0x10FFFF do
        t1 = Enum.at(root, cp >>> 13)
        t2 = Enum.at(middle, t1 * 64 + (cp >>> 7 &&& 0x3F))
        packed = Enum.at(leaves, t2 * 32 + (cp >>> 2 &&& 0x1F))
        packed >>> (2 * (cp &&& 3)) &&& 3
      end

    Enum.with_index(values)
    |> Enum.reduce({[], 0, hd(values)}, fn {value, cp}, {acc, start, previous} ->
      if value == previous,
        do: {acc, start, previous},
        else: {[{start, cp - 1, previous} | acc], cp, value}
    end)
    |> then(fn {acc, start, value} -> Enum.reverse([{start, 0x10FFFF, value} | acc]) end)
  end

  defp render_ranges(ranges),
    do:
      Enum.map_join(ranges, "\n", fn {lo, hi, width} ->
        "{0x#{hex(lo)}, 0x#{hex(hi)}, #{width}},"
      end)

  defp render_plain_ranges(ranges),
    do: Enum.map_join(ranges, "\n", fn {lo, hi} -> "{0x#{hex(lo)}, 0x#{hex(hi)}}," end)

  defp emoji_presentation_ranges(source) do
    bytes = static_bytes!(source, "EMOJI_PRESENTATION_LEAVES", "TEXT_PRESENTATION_LEAF_0")
    tops = [0x0, 0x8, 0x9, 0xA, 0xC, 0x7C, 0x7D]

    (for {top, row} <- Enum.with_index(tops), byte_index <- 0..127, bit <- 0..7,
         (Enum.at(bytes, row * 128 + byte_index) &&& (1 <<< bit)) != 0,
         do: (top <<< 10) + (byte_index <<< 3) + bit)
    |> compact_codepoints()
  end

  defp prefixed_ranges(source, prefix, tops) do
    tops
    |> Enum.with_index()
    |> Enum.flat_map(fn {top, index} ->
      pair_ranges(source, "#{prefix}_#{index}")
      |> Enum.map(fn {lo, hi} -> {(top <<< 8) + lo, (top <<< 8) + hi} end)
    end)
  end

  defp pair_ranges(source, name) do
    [_, body] = Regex.run(~r/static #{name}:[^=]*= \[(.*?)\n\];/s, source)

    Regex.scan(~r/\(0x([0-9A-Fa-f]+), 0x([0-9A-Fa-f]+)\)/, body,
      capture: :all_but_first
    )
    |> Enum.map(fn [lo, hi] -> {String.to_integer(lo, 16), String.to_integer(hi, 16)} end)
  end

  defp triplet_ranges(source, name) do
    [_, body] = Regex.run(~r/static #{name}:[^=]*= \[(.*?)\n\];/s, source)

    Regex.scan(
      ~r/\(\[0x([0-9A-Fa-f]+), 0x([0-9A-Fa-f]+), 0x([0-9A-Fa-f]+)\], \[0x([0-9A-Fa-f]+), 0x([0-9A-Fa-f]+), 0x([0-9A-Fa-f]+)\]\)/,
      body,
      capture: :all_but_first
    )
    |> Enum.map(fn values ->
      [a, b, c, d, e, f] = Enum.map(values, &String.to_integer(&1, 16))
      {a + (b <<< 8) + (c <<< 16), d + (e <<< 8) + (f <<< 16)}
    end)
  end

  defp compact_codepoints([first | rest]) do
    rest
    |> Enum.reduce({[], first, first}, fn cp, {acc, lo, hi} ->
      if cp == hi + 1, do: {acc, lo, cp}, else: {[{lo, hi} | acc], cp, cp}
    end)
    |> then(fn {acc, lo, hi} -> Enum.reverse([{lo, hi} | acc]) end)
  end

  defp hex(value), do: value |> Integer.to_string(16) |> String.upcase()

  defp generate_vectors! do
    source = Path.join(@root, "apps/swarm_code_cli/test/fixtures/unicode_width/vectors.json")
    atomic_write!(source, File.read!(source))
  end

  defp atomic_write!(dest, bytes) do
    File.mkdir_p!(Path.dirname(dest))
    tmp = dest <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.rename!(tmp, dest)
  end

  defp metadata!, do: @upstream |> File.read!() |> :json.decode()
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp fail!(message), do: raise(Mix.Error, message: message)
end

SyncUnicodeWidth.main(System.argv())
