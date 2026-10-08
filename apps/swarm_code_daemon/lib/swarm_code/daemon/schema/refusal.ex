defmodule SwarmCode.Daemon.Schema.Refusal do
  @moduledoc """
  The schema refusals a person can act on, as one sentence each (pass 70
  D2, and Q13 for a stray or damaged file). All keep the
  `:schema_incompatible` code, so every layer that already handles that code
  (the directory protocol, the launchers' exit status) treats them the same;
  only the words differ from the generic probe failure.
  """

  alias SwarmCode.Daemon.StartupError

  @doc """
  The database carries migrations this build does not know: the desktop is
  newer. The action names this CLI's version (cli020 A4), so the person can
  tell which build to replace.
  """
  @spec database_ahead() :: StartupError.t()
  def database_ahead do
    StartupError.new(
      :schema_incompatible,
      false,
      "This ncode database was upgraded by a newer ncode app than this ncode supports.",
      "Install the ncode CLI that matches your ncode app (ncode --version shows this one: " <>
        version() <> "); the database was not changed."
    )
  end

  defp version do
    case Application.spec(:swarm_code_daemon, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _unloaded -> "unknown"
    end
  end

  @doc "The file where the database belongs is not an SQLite database (pass70 Q13)."
  @spec not_a_database() :: StartupError.t()
  def not_a_database do
    StartupError.new(
      :schema_incompatible,
      false,
      "The file where your conversations database belongs is not an ncode database.",
      "Move swarm_code.db aside or restore it from a verified backup, then run ncode again; nothing was changed."
    )
  end

  @doc "The database fails SQLite's own integrity check (pass70 Q13)."
  @spec damaged() :: StartupError.t()
  def damaged do
    StartupError.new(
      :schema_incompatible,
      false,
      "Your conversations database failed SQLite's integrity check.",
      "Restore swarm_code.db from a verified backup, then run ncode again; nothing was changed."
    )
  end

  @doc """
  The database file (or one of its `-wal`/`-shm` sidecars) is owned by this
  user but its mode is not 0600 (cli020 fix S4). The sentence is the same for
  every path, so the launcher recognises it by its message; the path travels in
  the action, with the one command that fixes it.
  """
  @spec database_mode(Path.t()) :: StartupError.t()
  def database_mode(path) when is_binary(path) do
    StartupError.new(
      :schema_incompatible,
      false,
      "Your conversations database file has the wrong permissions.",
      "Run: chmod 600 " <> shell_word(path) <> " and then run ncode again; nothing was changed."
    )
  end

  # A path with a space (`Application Support`) or a quote must paste as one word.
  defp shell_word(path) do
    if path =~ ~r{\A[A-Za-z0-9_/.,:@%+=-]+\z},
      do: path,
      else: "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  @doc "A pending migration is not one the CLI may run ahead of the desktop."
  @spec desktop_upgrade_required() :: StartupError.t()
  def desktop_upgrade_required do
    StartupError.new(
      :schema_incompatible,
      false,
      "This ncode database needs an upgrade that only the ncode app makes.",
      "Open the ncode app once to upgrade the database, quit it, then run ncode again."
    )
  end
end
