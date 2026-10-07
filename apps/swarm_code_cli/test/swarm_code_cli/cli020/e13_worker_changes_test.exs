defmodule SwarmCodeCLI.Cli020.E13WorkerChangesTest do
  # cli020 E13 (ux-live-2 UI): a worker's report is drawn without the engine's
  # model-facing note, and with a dim `+N −M in K files` row (or `no file
  # changes`). The stored text keeps the note (the Lead reads it).
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Projector.Workspace.Turns

  @changes "Hardened the refresh path.\n\n[Changes on branch swarm/builder-4 (3 files changed, 40 insertions(+), 2 deletions(-)). Integrate them with the integrate_agent tool when they are good.]"

  test "the changes note becomes a stat row from changes_stat" do
    assert Turns.worker_report(@changes, "3 files changed, +40 −2") ==
             {"Hardened the refresh path.", "+40 −2 in 3 files"}
  end

  test "without changes_stat the note's own stat is read" do
    assert Turns.worker_report(@changes, nil) ==
             {"Hardened the refresh path.", "+40 −2 in 3 files"}
  end

  test "a report with no changes says so" do
    assert Turns.worker_report("Nothing to fix.\n\n[No file changes.]", nil) ==
             {"Nothing to fix.", "no file changes"}
  end

  test "a report without a note is unchanged" do
    assert Turns.worker_report("Plain words.", "+1 −0") == {"Plain words.", nil}
  end

  test "one file, insertions only" do
    assert Turns.worker_report(@changes, "1 file changed, 5 insertions(+)") ==
             {"Hardened the refresh path.", "+5 −0 in 1 file"}
  end
end
