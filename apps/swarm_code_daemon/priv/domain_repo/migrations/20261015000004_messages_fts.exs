defmodule SwarmCode.Domain.Repo.Migrations.MessagesFts do
  use Ecto.Migration

  # spec 70 D5: FTS5 virtual table for cross-session message search.
  # content= points at the existing messages table so no data is duplicated.
  # The rebuild populates the index from existing rows.
  def up do
    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
      content,
      content='messages',
      content_rowid='rowid'
    )
    """

    # Triggers to keep the FTS index in sync with the messages table.
    execute """
    CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content);
    END
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES('delete', old.rowid, old.content);
    END
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE OF content ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES('delete', old.rowid, old.content);
      INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content);
    END
    """

    # Populate the index from existing rows.
    execute "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS messages_fts_au"
    execute "DROP TRIGGER IF EXISTS messages_fts_ad"
    execute "DROP TRIGGER IF EXISTS messages_fts_ai"
    execute "DROP TABLE IF EXISTS messages_fts"
  end
end
