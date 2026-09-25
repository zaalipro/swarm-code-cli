defmodule SwarmCodeCLI.UI.DataSource.C74FFileViewTest do
  @moduledoc """
  cli74 F: the `file` view as the service answers it (a file record with
  `content` among its fields, §3.4.2) and as the fake answers it (the fields
  flat) both decode to `SettingsFile{fields, content}`; a missing file has no
  content. The sandbox found the service's shape refused ("Couldn't read
  settings right now." on Project file and Memory).
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsFile

  @fields %{
    "ref" => "project_config:project:p1:config",
    "path" => "/p/.swarm_code/config.json",
    "exists" => false
  }

  test "the service's file record decodes, with and without content" do
    record = %{
      "kind" => "file",
      "id" => @fields["ref"],
      "fields" => Map.put(@fields, "content", nil)
    }

    assert {:ok, %SettingsFile{content: nil, fields: fields}} =
             SettingsFile.decode(%{"file" => record})

    assert fields["path"] == "/p/.swarm_code/config.json"
    refute Map.has_key?(fields, "content")

    record = put_in(record, ["fields", "content"], "{}\n")
    assert {:ok, %SettingsFile{content: "{}\n"}} = SettingsFile.decode(%{"file" => record})
  end

  test "the flat form (the fake's) still decodes" do
    assert {:ok, %SettingsFile{content: "x"}} =
             SettingsFile.decode(%{"file" => Map.put(@fields, "content", "x")})
  end

  test "a flat answer without content is refused; a record without it reads as no content" do
    record = %{"kind" => "file", "id" => @fields["ref"], "fields" => @fields}
    assert {:error, _} = SettingsFile.decode(%{"file" => @fields})
    assert {:ok, %SettingsFile{content: nil}} = SettingsFile.decode(%{"file" => record})
  end
end
