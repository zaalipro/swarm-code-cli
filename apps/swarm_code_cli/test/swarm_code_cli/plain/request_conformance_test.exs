defmodule SwarmCodeCLI.Plain.RequestConformanceTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.Plain.{Command, Presenter}
  alias SwarmCodeCLI.UI.RequestResolver
  alias SwarmCodeCLI.TestSupport.RequestConformance, as: Fixtures

  test "independent command truth table fixes intent, exact context, requests and canonical bytes" do
    for row <- Fixtures.rows() do
      p = Fixtures.presenter(row)
      c = Fixtures.context(row)
      result = Command.parse(row["line"], p, c.scope)

      cond do
        row["error"] ->
          assert match?({:error, _}, result), row["name"]

        row["local"] ->
          assert result == {:ok, {:local, Fixtures.action(row["local"])}}, row["name"]
          refute Map.has_key?(row, "request")
          refute Map.has_key?(row, "canonical_base64")

        true ->
          expected = Fixtures.intent(row)
          assert result == {:ok, {:intent, expected}}, row["name"]
          assert {:ok, ^c} = Presenter.context(p, expected, c.scope)
          assert {:intent, ^expected} = Fixtures.tui_target(row)

          assert {:ok, tui_request} =
                   RequestResolver.resolve(expected, c, row["request_id"], row["deadline"])

          assert tui_request == Fixtures.request(row)
          assert Fixtures.encode(tui_request) == Base.decode64!(row["canonical_base64"])

          assert {:ok, plain_request} =
                   RequestResolver.resolve(expected, c, row["request_id"], row["deadline"])

          assert plain_request == Fixtures.request(row), row["name"]

          assert Fixtures.encode(plain_request) == Base.decode64!(row["canonical_base64"]),
                 row["name"]
      end
    end
  end
end
