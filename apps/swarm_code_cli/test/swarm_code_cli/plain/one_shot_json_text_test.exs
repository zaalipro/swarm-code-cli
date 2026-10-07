defmodule SwarmCodeCLI.Plain.OneShotJsonTextTest do
  @moduledoc """
  cli020 B5 (bugs-16): `--json` carries the model's exact text (Jason escapes
  what JSON must); the streamed text mode still strips terminal controls.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.OneShotHarness
  alias SwarmCodeCLI.Test.OneShotHarness, as: H

  setup do
    source = start_supervised!({H.Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    %{source: source, output: output, error: error}
  end

  test "--json keeps control characters, escaped by the encoder", context do
    session = start(context, format: :json) |> accept() |> run_update(:done)
    complete(session, [run(:done)], [message("red \e[31mtext\e[0m\r")])

    assert code(session) == 0
    raw = text(context.output)
    assert raw =~ ~S("text":"red \u001B[31mtext\u001B[0m\r")
    assert Jason.decode!(raw)["text"] == "red \e[31mtext\e[0m\r"
  end

  test "text mode strips them", context do
    session = start(context) |> accept() |> run_update(:done)
    complete(session, [run(:done)], [message("red \e[31mtext\e[0m")])

    assert code(session) == 0
    assert text(context.output) == "red [31mtext[0m\n"
  end
end
