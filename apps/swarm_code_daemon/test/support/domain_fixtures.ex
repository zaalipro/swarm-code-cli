defmodule SwarmCode.Domain.Fixtures do
  @moduledoc """
  The part of the desktop's `test/support/fixtures.ex` that the synced pure
  upstream tests use (`SwarmCode.Fixtures` after the sync rewrite). Nothing
  here touches a database or a global directory.
  """

  @doc """
  The words the assistant's system prompt opens with (`Prompts.assistant/1`),
  as the desktop's `SwarmCode.Fixtures.assistant_identity/0` says them.
  """
  @spec assistant_identity() :: String.t()
  def assistant_identity, do: "You are ncode"

  @doc """
  The desktop's `SwarmCode.Fixtures.eventually/2` (spec 74
  ARCHITECTURE-11): polls `fun` until it returns a truthy value, or the
  deadline passes; then the last attempt's exception or exit is re-raised, and
  a falsy value fails the test with `last: …`.
  """
  def eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    result =
      try do
        {:value, fun.()}
      rescue
        exception -> {:raised, :error, exception, __STACKTRACE__}
      catch
        :exit, reason -> {:raised, :exit, reason, __STACKTRACE__}
      end

    case result do
      {:value, value} when value not in [nil, false] ->
        value

      last ->
        if System.monotonic_time(:millisecond) > deadline do
          give_up(last)
        else
          Process.sleep(25)
          do_eventually(fun, deadline)
        end
    end
  end

  defp give_up({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  defp give_up({:value, value}),
    do: ExUnit.Assertions.flunk("eventually/2 timed out; last: #{inspect(value)}")

  @doc "A fresh private directory under the system temp dir (the desktop's `tmp_dir/0`)."
  @spec tmp_dir() :: Path.t()
  def tmp_dir do
    dir = Path.join([System.tmp_dir!(), "swarm_code_test", Ecto.UUID.generate()])
    File.mkdir_p!(dir)
    dir
  end
end
