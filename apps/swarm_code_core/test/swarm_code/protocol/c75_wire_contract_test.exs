defmodule SwarmCode.Protocol.C75WireContractTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.ServiceHandshake

  test "body_version is 1 for pass 75" do
    assert ServiceHandshake.hello() == %{
             "op" => "hello",
             "client" => "swarm-code-cli",
             "body_version" => 1
           }
  end

  test "a hello with another version is refused" do
    assert match?(
             {:error, _},
             ServiceHandshake.decode_hello(%{
               "op" => "hello",
               "client" => "swarm-code-cli",
               "body_version" => 2
             })
           )

    assert match?(
             {:ok, _},
             ServiceHandshake.decode_hello(%{
               "op" => "hello",
               "client" => "swarm-code-cli",
               "body_version" => 1
             })
           )
  end

  test "the pass-75 additions table exists" do
    root = Path.expand("../../../../..", __DIR__)
    notes = File.read!(Path.join(root, "docs/superpowers/plans/pass75-notes/wire.md"))

    assert notes =~ "| AgentSummary | turn | {:optional, :count} | nil |"
    assert notes =~ "| NeedsYou | options | :count | 0 |"
    assert notes =~ "body_version stays 1"
  end
end
