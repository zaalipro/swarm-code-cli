defmodule SwarmCode.Domain.Repo.Migrations.ColWidths do
  use Ecto.Migration

  # Spec 17 §3.1: the chat is the flexible column and the other two are pixel
  # widths the user drags — the side chat remembers a width for the two-column
  # layout and another for the three-column one.
  def change do
    alter table(:settings) do
      add :side_w_2col, :integer, default: 440, null: false
      add :side_w_3col, :integer, default: 380, null: false
      add :pane_w, :integer, default: 420, null: false
    end
  end
end
