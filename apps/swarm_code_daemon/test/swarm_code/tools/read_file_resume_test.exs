defmodule SwarmCode.Tools.ReadFileResumeTest do
  @moduledoc """
  cli020 A5: the desktop's `polish74_o2_read_file_test.exs` (09774f87)
  against the live runtime's `read_file` copy. Spec 74 BUGS-44: read_file's
  resume offset was computed before the 40 000-character cap cut the body, so
  up to about 1 200 lines were never read by a model that followed the hint.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Tools

  setup do
    dir = Path.join(System.tmp_dir!(), "live-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, ctx: %{project_root: dir}, p: fn _, _ -> :ok end}
  end

  # A 49-character line: "line NNNN " padded with dots.
  defp line(n), do: String.pad_trailing("line #{n} ", 49, ".")

  defp read(ctx, p, offset) do
    {:ok, out} = Tools.run("read_file", %{"path" => "big.txt", "offset" => offset}, ctx, p)
    out
  end

  test "the hint's offset follows the last line returned", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "big.txt"), Enum.map_join(1..3_000, "\n", &line/1) <> "\n")

    out = read(ctx, p, 1)
    [_header | body] = String.split(out, "\n")
    {shown, [suffix]} = Enum.split(body, -1)

    last = length(shown)
    assert List.last(shown) == line(last)
    assert suffix == "…[showing lines 1-#{last} of 3000; call again with offset=#{last + 1}]"
    assert String.length(Enum.join(shown, "\n")) <= 40_000
    assert last < 2_000
  end

  test "chaining read_file by its suffix covers every line exactly once", %{
    dir: dir,
    ctx: ctx,
    p: p
  } do
    File.write!(Path.join(dir, "big.txt"), Enum.map_join(1..3_000, "\n", &line/1) <> "\n")

    seen = chain(ctx, p, 1, [])
    assert seen == Enum.map(1..3_000, &line/1)
  end

  defp chain(ctx, p, offset, acc) do
    out = read(ctx, p, offset)
    [_header | body] = String.split(out, "\n")

    case Regex.run(~r/call again with offset=(\d+)\]$/, out) do
      [_, next] ->
        chain(ctx, p, String.to_integer(next), acc ++ Enum.drop(body, -1))

      nil ->
        acc ++ body
    end
  end

  test "a single line over the cap is cut and the next read starts after it", %{
    dir: dir,
    ctx: ctx,
    p: p
  } do
    File.write!(Path.join(dir, "big.txt"), String.duplicate("x", 50_000) <> "\nafter\n")

    out = read(ctx, p, 1)

    assert out =~
             "…[showing lines 1-1 of 2 (line 1 cut at 40000 of 50000 characters); call again with offset=2]"

    assert read(ctx, p, 2) == "big.txt (2 lines)\nafter"
  end
end
