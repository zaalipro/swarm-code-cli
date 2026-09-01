defmodule SwarmCode.Governance.ProvenanceTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Governance.Provenance

  test "pending authorization accepts an empty extraction ledger" do
    root = fixture_root!("pending", [])
    assert :ok = Provenance.verify(root)
  end

  test "pending authorization rejects copied source" do
    root = fixture_root!("pending", [entry("lib/copied.ex", String.duplicate("a", 64))])
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/copied.ex"), "copied")
    assert {:error, errors} = Provenance.verify(root)
    assert "source extraction is blocked while authorization is pending" in errors
  end

  test "authorized entries require exact destination hashes and pinned commit" do
    root = fixture_root!("authorized", [entry("lib/copied.ex", String.duplicate("0", 64))])
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/copied.ex"), "copied")
    assert {:error, errors} = Provenance.verify(root)
    assert Enum.any?(errors, &String.contains?(&1, "sha256 mismatch"))
  end

  test "absolute, parent-traversing, and symlink destinations are rejected" do
    outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}")
    File.write!(outside, "outside")
    root = fixture_root!("authorized", [entry(outside, sha256("outside"))])
    File.ln_s!(outside, Path.join(root, "linked.ex"))

    ledger = %{
      "version" => 1,
      "entries" => [
        entry(outside, sha256("outside")),
        entry("linked.ex", sha256("outside")),
        entry("../outside.ex", sha256("outside"))
      ]
    }

    File.write!(Path.join(root, "provenance/extracted-files.json"), Jason.encode!(ledger))
    assert {:error, errors} = Provenance.verify(root)
    assert Enum.count(errors, &String.contains?(&1, "unconfined provenance destination")) == 2
    assert Enum.any?(errors, &String.contains?(&1, "missing or not regular"))
    File.rm!(outside)
  end

  defp entry(path, hash) do
    %{
      "destination" => path,
      "upstream_path" => "lib/swarm_code/example.ex",
      "upstream_commit" => "dbb8804b3d7293178e571fa7afdf6bd47d06a51c",
      "sha256" => hash,
      "classification" => "source"
    }
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp fixture_root!(status, entries) do
    root = Path.join(System.tmp_dir!(), "provenance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "governance"))
    File.mkdir_p!(Path.join(root, "provenance"))
    File.write!(Path.join(root, "governance/source-policy.json"), Jason.encode!(policy(status)))

    File.write!(
      Path.join(root, "provenance/extracted-files.json"),
      Jason.encode!(%{"version" => 1, "entries" => entries})
    )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp policy(status) do
    %{
      "version" => 1,
      "audit_baseline" => "dbb8804b3d7293178e571fa7afdf6bd47d06a51c",
      "authorization_status" => status,
      "public_source_copying_allowed" => status == "authorized",
      "copyright_terms_recorded" => status == "authorized",
      "license_terms_recorded" => status == "authorized",
      "notice_terms_recorded" => status == "authorized"
    }
  end
end
