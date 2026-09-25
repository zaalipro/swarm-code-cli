defmodule SwarmCode.Daemon.Service.Settings.C74FeatureErrorsTest do
  @moduledoc """
  pass74 S1-11 (R1): a feature request's error carries the canonical message
  of its code — the one the client's `AdmissionError.decode/1` accepts — so a
  refused feature action no longer closes the connection.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Service.FeatureRequest
  alias SwarmCodeCLI.UI.DataSource.AdmissionError

  test "the daemon's table agrees with the client's by value" do
    for {code, message} <- FeatureRequest.canonical_messages() do
      assert AdmissionError.new(code).message == message

      assert {:ok, %AdmissionError{code: ^code}} =
               AdmissionError.decode(%{"code" => Atom.to_string(code), "message" => message})
    end

    assert Map.keys(FeatureRequest.canonical_messages()) |> Enum.sort() ==
             Enum.sort([:not_allowed, :invalid_request, :capacity_exceeded, :source_unavailable])
  end
end
