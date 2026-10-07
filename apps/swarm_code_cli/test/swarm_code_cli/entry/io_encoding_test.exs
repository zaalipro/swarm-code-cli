defmodule SwarmCodeCLI.Release.IoEncodingTest do
  @moduledoc """
  cli020 B2 (bugs-3): under `LANG=C` the VM opens stdio as latin1;
  `Release.configure_io/0` puts it in unicode mode, so a `--json` summary
  with non-ASCII text is written whole.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Release

  test "configure_io/0 turns a latin1 group leader into a unicode one" do
    {:ok, device} = StringIO.open("", encoding: :latin1)
    parent = self()

    spawn(fn ->
      Process.group_leader(self(), device)
      before = :io.getopts(:standard_io)[:encoding]
      :ok = Release.configure_io()
      after_set = :io.getopts(:standard_io)[:encoding]
      IO.write(Jason.encode!(%{"text" => "done ✓ héllo"}))
      send(parent, {:encodings, before, after_set})
    end)

    assert_receive {:encodings, :latin1, :unicode}, 5_000
    {_, written} = StringIO.contents(device)
    assert Jason.decode!(written) == %{"text" => "done ✓ héllo"}
  end
end
