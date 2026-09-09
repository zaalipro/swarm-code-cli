defmodule SwarmCode.Domain.Engine.SpecTemplate do
  @moduledoc """
  The owner's spec-writing workflow (spec 45 §6.1): `~/.spec.md` when the
  file exists, else the copy bundled as `priv/spec_master.md`. The planner
  reads the whole thing as its "SPEC WORKFLOW"; the implementer reads only
  the "How to implement" block.
  """

  @doc "The whole template, the owner's own file first."
  @spec read() :: String.t()
  def read do
    # `HOME` first (the VM caches `System.user_home/0` at boot, which a test
    # cannot redirect), the cached home when it is unset.
    home = System.get_env("HOME") || System.user_home!()

    case File.read(Path.join(home, ".spec.md")) do
      {:ok, text} when byte_size(text) > 0 -> text
      _other -> File.read!(bundled())
    end
  end

  @doc "`priv/spec_master.md`."
  @spec bundled() :: String.t()
  def bundled, do: Path.join(:code.priv_dir(:swarm_code_daemon), "spec_master.md")

  @implement_head "# How to implement"

  @doc """
  The "How to implement" block — the fenced markdown under "## Implementer
  instructions", from `# How to implement` to its `None` (spec 45 §6.1). A
  template without the block falls back to the bundled one; the bundled one
  is known to carry it.
  """
  @spec implement_block() :: String.t()
  def implement_block do
    case extract(read()) do
      nil -> extract(File.read!(bundled())) || @implement_head
      block -> block
    end
  end

  @doc false
  # The first fenced block after "## Implementer instructions" whose body
  # starts with the heading; the fence lines themselves are not part of it.
  @spec extract(String.t()) :: String.t() | nil
  def extract(text) do
    with [_before, rest] <- String.split(text, "## Implementer instructions", parts: 2),
         [_intro, fenced | _] <- String.split(rest, ~r/^```\w*\n/m, parts: 3),
         [body | _] <- String.split(fenced, ~r/^```/m, parts: 2),
         body = String.trim(body),
         true <- String.starts_with?(body, @implement_head) do
      body
    else
      _other -> nil
    end
  end
end
