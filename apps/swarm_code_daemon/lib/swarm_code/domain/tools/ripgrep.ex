defmodule SwarmCode.Domain.Tools.Ripgrep do
  @moduledoc """
  Detect and cache the ripgrep (`rg`) binary path and its PCRE2 capability.
  # spec 70 C1
  """

  @doc "Absolute path to `rg`, or nil when it is not installed."
  @spec rg_path() :: String.t() | nil
  def rg_path do
    case :persistent_term.get({__MODULE__, :rg_path}, :unset) do
      :unset -> detect_and_cache()
      cached -> cached
    end
  end

  @doc "True when the detected `rg` binary accepts `--pcre2`."
  @spec pcre2?() :: boolean()
  def pcre2? do
    case :persistent_term.get({__MODULE__, :pcre2}, :unset) do
      :unset ->
        # force detection
        rg_path()
        :persistent_term.get({__MODULE__, :pcre2}, false)

      cached ->
        cached
    end
  end

  @doc "True when `rg` is available."
  @spec available?() :: boolean()
  def available?, do: rg_path() != nil

  defp detect_and_cache do
    path = System.find_executable("rg")
    pcre2 = if path, do: test_pcre2(path), else: false
    :persistent_term.put({__MODULE__, :rg_path}, path)
    :persistent_term.put({__MODULE__, :pcre2}, pcre2)
    path
  end

  defp test_pcre2(path) do
    case System.cmd(path, ["--pcre2", "--version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # Test seam: reset the cache so a test can inject a fake binary.
  @doc false
  def reset_cache do
    :persistent_term.erase({__MODULE__, :rg_path})
    :persistent_term.erase({__MODULE__, :pcre2})
  end
end
