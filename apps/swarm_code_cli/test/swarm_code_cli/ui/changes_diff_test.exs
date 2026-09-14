defmodule SwarmCodeCLI.UI.ChangesDiffTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Init, Projector, Reducer, SafeText, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @diff """
  diff --git a/lib/foo.ex b/lib/foo.ex
  --- a/lib/foo.ex
  +++ b/lib/foo.ex
  @@ -1,3 +1,3 @@
   unchanged
  -was here
  +is here now
  """

  defp changes_scene(detail) do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch"
      })

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :changes}})

    body = %DTO.LibrarySnapshot{
      feature: :changes,
      request_id: request.request_id,
      items: [
        %DTO.LibraryItem{
          id: "lib/foo.ex",
          title: "lib/foo.ex",
          subtitle: "main",
          status: "changed",
          detail: detail,
          actions: [:diff]
        }
      ]
    }

    {ready, []} = SwarmCodeCLI.UI.Library.response(state, request, body)
    {selected, _} = Reducer.update(ready, {:library_select, "lib/foo.ex"})
    {scene, _} = Projector.project(selected)
    scene
  end

  defp body_text(scene) do
    scene.overlay.blocks
    |> Enum.flat_map(fn
      %{spans: spans} -> Enum.map(spans, &SafeText.value(&1.text))
      %{text: text} -> [SafeText.value(text)]
      _ -> []
    end)
  end

  test "a selected change renders its diff one line per row" do
    lines = @diff |> changes_scene() |> body_text()

    assert Enum.any?(lines, &String.contains?(&1, "+1"))
    assert Enum.any?(lines, &String.starts_with?(String.trim_leading(&1), "@@"))
    assert Enum.any?(lines, &String.contains?(&1, "-was here"))
    assert Enum.any?(lines, &String.contains?(&1, "+is here now"))
  end

  test "diff lines are not collapsed onto a single row" do
    lines = @diff |> changes_scene() |> body_text()

    refute Enum.any?(lines, fn line ->
             String.contains?(line, "-was here") and String.contains?(line, "+is here now")
           end)
  end

  test "a non-diff detail still renders for other features" do
    lines = "just a plain detail" |> changes_scene() |> body_text()
    assert Enum.any?(lines, &String.contains?(&1, "just a plain detail"))
  end

  test "the Diff action re-queries this page for the selected path" do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch"
      })

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :changes}})

    body = %DTO.LibrarySnapshot{
      feature: :changes,
      request_id: request.request_id,
      items: [
        %DTO.LibraryItem{
          id: "lib/foo.ex",
          title: "lib/foo.ex",
          status: "changed",
          actions: [:diff]
        }
      ]
    }

    {ready, []} = SwarmCodeCLI.UI.Library.response(state, request, body)

    # Diff is a query for one path's detail, not a command the domain defines.
    {_state, [{:query, followup}]} =
      Reducer.update(ready, {:library_command, :changes, "lib/foo.ex", :diff})

    assert {:feature_query, :changes, "lib/foo.ex", _cursor, _size, _bytes} = followup.kind
  end

  test "Diff is offered as an action on a changed file" do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch"
      })

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :changes}})

    body = %DTO.LibrarySnapshot{
      feature: :changes,
      request_id: request.request_id,
      items: [
        %DTO.LibraryItem{
          id: "lib/foo.ex",
          title: "lib/foo.ex",
          status: "changed",
          actions: [:diff]
        }
      ]
    }

    {ready, []} = SwarmCodeCLI.UI.Library.response(state, request, body)
    {selected, _} = Reducer.update(ready, {:library_select, "lib/foo.ex"})
    {scene, _} = Projector.project(selected)

    assert Enum.any?(scene.overlay.footer, fn control ->
             Map.has_key?(control, :text) and SafeText.value(control.text) =~ "Diff"
           end)
  end
end
