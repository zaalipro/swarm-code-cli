defmodule SwarmCodeCLI.UI.DataSource.FeatureFormSchemaTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.DataSource.DTO

  test "decodes bounded feature form and legacy library row" do
    wire = %{
      "id" => "x",
      "title" => "X",
      "subtitle" => "",
      "status" => "",
      "detail" => "",
      "actions" => [],
      "form" => %{
        "title" => "T",
        "submit_label" => "Save",
        "action" => "save",
        "fields" => [
          %{
            "key" => "arg:name",
            "label" => "Name",
            "kind" => "text",
            "value" => "",
            "required" => true,
            "choices" => [],
            "hint" => ""
          }
        ]
      }
    }

    assert {:ok, row} = DTO.LibraryItem.decode(wire)
    assert row.form.fields |> hd() |> Map.get(:key) == "arg:name"
    assert {:ok, legacy} = DTO.LibraryItem.decode(Map.drop(wire, ["form"]))
    assert legacy.form == nil
  end

  test "rejects forms over 32 fields" do
    field = %{
      "key" => "x",
      "label" => "x",
      "kind" => "text",
      "value" => "",
      "required" => false,
      "choices" => [],
      "hint" => ""
    }

    form = %{
      "title" => "",
      "submit_label" => "",
      "action" => "save",
      "fields" => List.duplicate(field, 33)
    }

    wire = %{
      "id" => "x",
      "title" => "X",
      "subtitle" => "",
      "status" => "",
      "detail" => "",
      "actions" => [],
      "form" => form
    }

    assert {:error, :invalid_dto} = DTO.LibraryItem.decode(wire)
  end
end
