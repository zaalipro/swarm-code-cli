defmodule SwarmCodeCLI.UI.Cli020.D14EditorCommandTest do
  @moduledoc "cli020 D14 (bugs-14): the editor command is quote-aware."
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.SessionRuntime

  setup do
    dir =
      Path.join(System.tmp_dir!(), "ncode d14 #{System.unique_integer([:positive])}/my editor")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(Path.dirname(dir)) end)
    script = Path.join(dir, "e")
    File.write!(script, "#!/bin/sh\n[ \"$1\" = \"--wait\" ] || exit 3\nprintf edited > \"$2\"\n")
    File.chmod!(script, 0o700)
    file = Path.join(Path.dirname(dir), "draft.txt")
    File.write!(file, "before")
    %{script: script, draft: file}
  end

  test "a quoted path with a space and an argument runs", %{script: script, draft: file} do
    assert :ok = SessionRuntime.run_editor(file, ~s("#{script}" --wait))
    assert File.read!(file) == "edited"
  end

  test "a plain command still gets the file as its last argument", %{draft: file} do
    assert {:error, {:exit, 3}} = SessionRuntime.run_editor(file, "/bin/sh -c 'exit 3' x")
    assert :ok = SessionRuntime.run_editor(file, "true")
  end
end
