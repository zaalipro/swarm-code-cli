defmodule SwarmCodeCLI.UI.DataSource.FixSFakeTrustTest do
  @moduledoc """
  cli020 fix S3: the fake agrees with the service. A mode picked by hand marks
  an untrusted project trusted and the toast says so; a trusted project keeps
  the plain `Approval mode: ...` words.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Session}

  defp script(trusted?, mode) do
    {:ok, script} =
      Script.decode(
        File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
      )

    %{script | session: %{script.session | trusted: trusted?, approval_mode: mode}}
  end

  defp pick(script, mode) do
    {:ok, next, deltas, _ids} =
      Session.prepare(script, %{kind: {:project_update, mode, nil}, request_id: "r-1"})

    [%Delta{body: %DTO.Toast{text: text}}] = for %Delta{kind: :toast} = d <- deltas, do: d
    {next.session, text}
  end

  test "an untrusted project picked to auto becomes trusted, and the toast says so" do
    {session, text} = pick(script(false, :read_only), :auto)

    assert text == "Approvals: read-only → auto · this project is now trusted"
    assert {session.approval_mode, session.trusted} == {:auto, true}
  end

  test "a trusted project keeps the plain words" do
    {_session, text} = pick(script(true, :read_only), :full_access)
    assert text == "Approval mode: full access"
  end
end
