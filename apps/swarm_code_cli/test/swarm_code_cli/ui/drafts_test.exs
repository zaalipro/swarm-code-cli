defmodule SwarmCodeCLI.UI.DraftsTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Draft, Drafts, Editor, SafeText}
  alias SwarmCodeCLI.UI.Draft.AttachmentRef

  test "dirty tracks content, targeting and staged metadata, not presentation" do
    draft = Draft.new({"a", :main}, Editor.new())
    refute Draft.dirty?(draft)
    refute Draft.dirty?(%{draft | editor: editor("  \n"), height: 8, scroll_x: 3, scroll_y: 7})

    for changed <- [
          %{draft | editor: editor("prompt")},
          %{draft | target: {:reply, "run"}},
          %{draft | chips: [{:goal, "goal", SafeText.chrome(:main)}]},
          %{draft | attachments: [attachment()]},
          %{draft | staged_validation: {:pending, "validation"}},
          %{draft | staged_validation: {:valid, "validation"}},
          %{draft | staged_validation: {:invalid, ["invalid_attachment"]}}
        ] do
      assert Draft.dirty?(changed)
    end
  end

  test "navigation restores each exact editor and draft metadata" do
    {:ok, selected} = Editor.apply(editor("ქართული"), {:extend_selection, :left})
    a = %{Draft.new({"a", :main}, selected) | target: {:reply, "run-a"}, height: 6}
    b = Draft.new({"b", {:thread, "run-b"}}, editor("B draft"))
    store = Drafts.new() |> Drafts.put(a) |> Drafts.put(b)
    assert Drafts.fetch(store, a.key) == a
    assert Drafts.fetch(store, b.key) == b
    assert Editor.text(Drafts.fetch(store, {"a", {:edit, "message"}}).editor) == ""
  end

  test "accepted submission clears only its originating draft and exact request" do
    a = Draft.new({"a", :main}, editor("A draft"))
    b = Draft.new({"b", :main}, editor("B draft"))

    store =
      Drafts.new() |> Drafts.put(a) |> Drafts.put(b) |> Drafts.mark_submitted(a.key, "request-a")

    assert Drafts.clear_origin(store, a.key, "wrong-request") == store
    cleared = Drafts.clear_origin(store, a.key, "request-a")
    refute Draft.dirty?(Drafts.fetch(cleared, a.key))
    assert Drafts.fetch(cleared, b.key) == b
    assert Drafts.clear_origin(cleared, a.key, "request-a") == cleared
  end

  test "late accepted response preserves edits and newer submissions" do
    key = {"a", :main}
    initial = Draft.new(key, editor("original"))
    store = Drafts.new() |> Drafts.put(initial) |> Drafts.mark_submitted(key, "request-1")
    changed = %{Drafts.fetch(store, key) | editor: editor("new prompt")}
    changed_store = Drafts.put(store, changed)
    assert Drafts.clear_origin(changed_store, key, "request-1") == changed_store

    newer = Drafts.mark_submitted(changed_store, key, "request-2")
    assert Drafts.clear_origin(newer, key, "request-1") == newer
    refute Draft.dirty?(newer |> Drafts.clear_origin(key, "request-2") |> Drafts.fetch(key))
  end

  test "cursor-only change does not prevent clearing a successfully submitted payload" do
    key = {"a", :main}

    store =
      Drafts.new()
      |> Drafts.put(Draft.new(key, editor("prompt")))
      |> Drafts.mark_submitted(key, "request")

    draft = Drafts.fetch(store, key)
    {:ok, moved} = Editor.apply(draft.editor, {:move, :left})
    store = Drafts.put(store, %{draft | editor: moved, height: 6})
    cleared = store |> Drafts.clear_origin(key, "request") |> Drafts.fetch(key)
    refute Draft.dirty?(cleared)
    assert cleared.height == 6
  end

  test "settling a send cannot reuse a stale undo timer identity" do
    key = {"a", :main}
    {:ok, original} = Editor.apply(Editor.new(), {:insert, "prompt"})
    stale_boundary = Editor.undo_group_id(original)

    draft =
      Drafts.new()
      |> Drafts.put(Draft.new(key, original))
      |> Drafts.mark_submitted(key, "request")
      |> Drafts.clear_origin(key, "request")
      |> Drafts.fetch(key)

    {:ok, fresh} = Editor.apply(draft.editor, {:insert, "new prompt"})
    {:ok, after_stale} = Editor.apply(fresh, {:undo_boundary, stale_boundary})
    assert after_stale == fresh
    assert Editor.undo_group_id(after_stale) != stale_boundary
  end

  test "store capacity never silently evicts unsent text" do
    a = Draft.new({"a", :main}, editor("unsent"))
    store = Drafts.new(max_drafts: 1) |> Drafts.put(a)

    assert_raise ArgumentError, ~r/draft capacity/, fn ->
      Drafts.put(store, Draft.new({"b", :main}, Editor.new()))
    end

    assert Editor.text(Drafts.fetch(store, a.key).editor) == "unsent"
  end

  test "attachments are validated metadata only and every container redacts content" do
    ref = attachment()
    assert AttachmentRef.validate(ref) == :ok

    assert AttachmentRef.validate(Map.put(ref, :bytes, "image bytes")) ==
             {:error, :invalid_attachment_ref}

    draft = %{Draft.new({"a", :main}, editor("canary secret")) | attachments: [ref]}
    store = Drafts.new() |> Drafts.put(draft) |> Drafts.mark_submitted(draft.key, "request")
    refute inspect(store) =~ "canary"
    refute inspect(draft) =~ "canary"
    refute inspect(ref) =~ "attachment-ref"
    assert_raise ArgumentError, fn -> Drafts.put(store, %{draft | height: 9}) end
    assert_raise ArgumentError, fn -> Draft.new({"bad", :unknown}, Editor.new()) end
  end

  defp editor(text) do
    {:ok, editor} = Editor.apply(Editor.new(), {:paste, text})
    editor
  end

  defp attachment do
    AttachmentRef.new!(
      id: "image",
      name: SafeText.chrome(:main),
      media_type: "image/png",
      byte_size: 512,
      width: 100,
      height: 100,
      status: :ready,
      reference: "attachment-ref"
    )
  end
end
