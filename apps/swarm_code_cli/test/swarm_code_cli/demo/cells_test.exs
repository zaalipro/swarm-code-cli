defmodule SwarmCodeCLI.Demo.CellsTest do
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.Demo.Cells

  @repo Path.expand("../../../../..", __DIR__)
  @child Path.join(@repo, "apps/swarm_code_cli")

  test "fixed preview export creates a fresh passive gallery with every supported fixture" do
    started = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    assert ExUnit.CaptureIO.capture_io(fn -> send(self(), {:export, Cells.run()}) end) == ""
    assert_receive {:export, {:ok, %{directory: directory, files: files}}}
    assert Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort() == started
    on_exit(fn -> File.rm_rf!(directory) end)

    assert Path.dirname(directory) == Path.join(@repo, "_build/cell-previews")
    assert files == Enum.sort(files)
    assert length(files) == 18
    assert "index.html" in files
    assert Enum.sort(File.ls!(directory)) == files

    for kind <- [:chat, :swarm, :consensus, :research],
        {columns, rows} <- [{80, 24}, {120, 40}, {160, 50}] do
      filename = "#{kind}-#{columns}x#{rows}-truecolor.svg"
      assert filename in files
      assert_svg(Path.join(directory, filename), columns, rows)
    end

    for kind <- [:question, :confirmation], {columns, rows} <- [{80, 24}, {50, 16}] do
      filename = "#{kind}-#{columns}x#{rows}-monochrome-ascii.svg"
      assert filename in files
      svg = assert_svg(Path.join(directory, filename), columns, rows)
      assert svg =~ "data-focus=\"dialog\""
    end

    svg = assert_svg(Path.join(directory, "too-small-49x13-monochrome-ascii.svg"), 49, 13)
    refute svg =~ "data-action="

    html = File.read!(Path.join(directory, "index.html"))
    assert html =~ "FAKE DEMO"
    assert html =~ "Synthetic cell previews"
    refute html =~ ~r/<script|<iframe|https?:|javascript:|onload=/i

    sources =
      Regex.scan(~r/<img[^>]*src="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()

    assert Enum.sort(sources) == files -- ["index.html"]

    assert {:ok, %{directory: second}} = Cells.run()
    on_exit(fn -> File.rm_rf!(second) end)
    refute second == directory
  end

  test "ancestor checks reject symlinks and non-directories without writing to them" do
    temp = Path.join(@repo, "_build/cell-safety-test-#{System.unique_integer([:positive])}")
    File.mkdir!(temp)
    on_exit(fn -> File.rm_rf!(temp) end)
    target = Path.join(temp, "target")
    File.mkdir!(target)
    link = Path.join(temp, "link")
    File.ln_s!(target, link)
    regular = Path.join(temp, "regular")
    File.write!(regular, "untouched")

    assert :ok = Cells.Directory.check_ancestors(Path.join(target, "missing/child"))

    assert {:error, :unsafe_output_path} =
             Cells.Directory.check_ancestors(Path.join(link, "child"))

    assert {:error, :unsafe_output_path} = Cells.Directory.check_ancestors(link)

    assert {:error, :unsafe_output_path} =
             Cells.Directory.check_ancestors(Path.join(regular, "child"))

    assert File.ls!(target) == []
    assert File.read!(regular) == "untouched"
  end

  test "real child-project command exports files and rejects arguments and umbrella invocation" do
    {output, 0} = System.cmd("mix", ["swarm_code.demo.cells"], cd: @child, stderr_to_stdout: true)
    [_, directory] = Regex.run(~r/Cell previews: (.+) \(18 files\)/, output)
    on_exit(fn -> File.rm_rf!(directory) end)
    assert length(File.ls!(directory)) == 18
    assert_svg(Path.join(directory, "chat-80x24-truecolor.svg"), 80, 24)

    {unknown, status} =
      System.cmd("mix", ["swarm_code.demo.cells", "--output", "/tmp/ignored"],
        cd: @child,
        stderr_to_stdout: true
      )

    assert status != 0
    assert unknown =~ "does not accept arguments"

    {umbrella, status} =
      System.cmd("mix", ["swarm_code.demo.cells"], cd: @repo, stderr_to_stdout: true)

    assert status != 0
    assert umbrella =~ "Run this task from apps/swarm_code_cli"
  end

  defp assert_svg(path, columns, rows) do
    svg = File.read!(path)
    assert svg =~ "<svg"
    assert svg =~ "viewBox=\"0 0 #{columns * 10} #{rows * 20}\""
    assert svg =~ "</svg>"
    refute svg =~ ~r/<script|<image|<foreignObject|javascript:|onload=/i

    assert {"", 0} =
             System.cmd(
               "python3",
               [
                 "-c",
                 "import sys, xml.etree.ElementTree as ET; assert ET.parse(sys.argv[1]).getroot().tag == '{http://www.w3.org/2000/svg}svg'",
                 path
               ],
               stderr_to_stdout: true
             )

    svg
  end
end
