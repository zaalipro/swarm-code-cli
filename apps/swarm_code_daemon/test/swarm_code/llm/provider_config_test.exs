defmodule SwarmCode.LLM.ProviderConfigTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Providers.Provider

  test "configuration is validated without a database and secrets are omitted from inspection" do
    assert {:ok, provider} =
             Provider.new(
               kind: "openai",
               name: "fixture",
               base_url: " http://localhost:4000/ ",
               api_key: "private-fixture-key"
             )

    assert provider.kind == "openai"
    assert provider.base_url == "http://localhost:4000"
    refute inspect(provider) =~ "private-fixture-key"
    assert is_binary(provider.id)
    assert {:error, _} = Provider.new(kind: "fake", name: "f", base_url: "http://localhost")
    assert {:error, _} = Provider.new(kind: "openai", name: "f", base_url: "file:///tmp/secret")

    assert {:error, _} =
             Provider.new(kind: "openai", name: "f", base_url: "https://key:secret@example.com")

    assert {:error, _} =
             Provider.new(
               kind: "anthropic",
               name: "f",
               base_url: "http://localhost",
               effort_levels: [%{"key" => "INVALID"}]
             )
  end

  test "effort settings normalize atom-keyed input and malformed configuration returns errors" do
    attrs = %{
      kind: "openai",
      name: "f",
      base_url: "http://localhost",
      effort_levels: [%{key: "custom", body: %{"reasoning_effort" => "high"}}]
    }

    assert {:ok, provider} = Provider.new(attrs)

    assert [%{"key" => "custom", "body" => %{"reasoning_effort" => "high"}}] =
             provider.effort_levels

    assert {:error, _} = Provider.new(%{attrs | effort_levels: [%{key: %{invalid: true}}]})
  end
end
