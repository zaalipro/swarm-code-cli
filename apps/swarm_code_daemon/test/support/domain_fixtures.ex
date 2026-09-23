defmodule SwarmCode.Domain.Fixtures do
  @moduledoc """
  The part of the desktop's `test/support/fixtures.ex` that the synced pure
  upstream tests use (`SwarmCode.Fixtures` after the sync rewrite). Nothing
  here touches a database or a global directory.
  """

  @doc "A fresh private directory under the system temp dir (the desktop's `tmp_dir/0`)."
  @spec tmp_dir() :: Path.t()
  def tmp_dir do
    dir = Path.join([System.tmp_dir!(), "swarm_code_test", Ecto.UUID.generate()])
    File.mkdir_p!(dir)
    dir
  end
end
