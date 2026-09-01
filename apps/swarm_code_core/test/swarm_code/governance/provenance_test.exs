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
    on_exit(fn -> File.rm(outside) end)
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
  end

  test "tilde-expanded destinations are rejected before reading outside the root" do
    basename = "provenance-outside-#{System.unique_integer([:positive])}.ex"
    outside = Path.join(System.user_home!(), basename)
    File.write!(outside, "outside")
    on_exit(fn -> File.rm(outside) end)

    root = fixture_root!("authorized", [entry("~/#{basename}", sha256("outside"))])

    assert {:error, errors} = Provenance.verify(root)
    assert "unconfined provenance destination" in errors
  end

  test "symlinked destination ancestors are rejected before reading outside the root" do
    outside = Path.join(System.tmp_dir!(), "outside-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "copied.ex"), "outside")
    on_exit(fn -> File.rm_rf!(outside) end)

    root = fixture_root!("authorized", [])
    File.ln_s!(outside, Path.join(root, "escape"))
    write_ledger!(root, [entry("escape/copied.ex", sha256("outside"))])

    assert {:error, errors} = Provenance.verify(root)
    assert "provenance destination is missing or not regular" in errors
  end

  test "authorized policies require every authorization flag to be literal true" do
    root = fixture_root!("authorized", [])

    for flag <- authorization_flags(), invalid <- ["true", 1, [], %{}, nil, false] do
      write_policy!(root, Map.put(policy("authorized"), flag, invalid))

      assert {:error,
              ["authorized extraction requires copying, copyright, license, and NOTICE records"]} =
               Provenance.verify(root)
    end
  end

  test "a complete five-key entry with a canonical digest verifies" do
    {root, valid_entry} = valid_entry_fixture!()
    write_ledger!(root, [valid_entry])

    assert :ok = Provenance.verify(root)
  end

  test "entries reject every missing required key" do
    {root, valid_entry} = valid_entry_fixture!()

    for key <- Map.keys(valid_entry) do
      write_ledger!(root, [Map.delete(valid_entry, key)])
      assert {:error, ["provenance entry has an invalid shape"]} = Provenance.verify(root)
    end
  end

  test "entries reject null required values" do
    {root, valid_entry} = valid_entry_fixture!()

    for key <- Map.keys(valid_entry) do
      write_ledger!(root, [Map.put(valid_entry, key, nil)])
      assert {:error, ["provenance entry has an invalid shape"]} = Provenance.verify(root)
    end
  end

  test "entries reject non-string required values" do
    {root, valid_entry} = valid_entry_fixture!()

    for key <- Map.keys(valid_entry) do
      write_ledger!(root, [Map.put(valid_entry, key, 123)])
      assert {:error, ["provenance entry has an invalid shape"]} = Provenance.verify(root)
    end
  end

  test "entries reject extra keys" do
    {root, valid_entry} = valid_entry_fixture!()
    write_ledger!(root, [Map.put(valid_entry, "unexpected", "value")])

    assert {:error, ["provenance entry has an invalid shape"]} = Provenance.verify(root)
  end

  test "entries require a nonempty confined relative upstream path" do
    {root, valid_entry} = valid_entry_fixture!()

    for invalid <- ["", "/lib/copied.ex", "../lib/copied.ex", "~/lib/copied.ex"] do
      write_ledger!(root, [Map.put(valid_entry, "upstream_path", invalid)])
      assert {:error, errors} = Provenance.verify(root)
      assert "invalid provenance upstream path" in errors
    end
  end

  test "entries require a canonical lowercase 64-hex digest" do
    {root, valid_entry} = valid_entry_fixture!()

    for invalid <- [
          String.duplicate("0", 63),
          String.duplicate("g", 64),
          String.upcase(valid_entry["sha256"]),
          ""
        ] do
      write_ledger!(root, [Map.put(valid_entry, "sha256", invalid)])
      assert {:error, errors} = Provenance.verify(root)
      assert "invalid provenance sha256" in errors
    end
  end

  test "scalar and list policies return a deterministic error" do
    root = fixture_root!("authorized", [])

    for malformed <- [1, []] do
      write_policy!(root, malformed)
      assert {:error, ["source policy has an invalid shape"]} = Provenance.verify(root)
    end
  end

  test "malformed top-level ledgers return a deterministic error" do
    root = fixture_root!("authorized", [])

    for malformed <- [1, [], %{"version" => 1, "entries" => "not a list"}] do
      write_json!(Path.join(root, "provenance/extracted-files.json"), malformed)

      assert {:error, ["extracted-files ledger has an invalid shape"]} =
               Provenance.verify(root)
    end
  end

  test "non-map ledger entries return a deterministic error" do
    root = fixture_root!("authorized", [])

    for malformed <- [nil, 1, [], "entry"] do
      write_ledger!(root, [malformed])
      assert {:error, ["provenance entry has an invalid shape"]} = Provenance.verify(root)
    end
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

    for file <- ~w(LICENSE NOTICE SOURCE_AUTHORIZATION.md) do
      File.write!(Path.join(root, file), file)
    end

    write_policy!(root, policy(status))
    write_ledger!(root, entries)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp valid_entry_fixture! do
    root = fixture_root!("authorized", [])
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/copied.ex"), "copied")
    {root, entry("lib/copied.ex", sha256("copied"))}
  end

  defp write_policy!(root, value) do
    write_json!(Path.join(root, "governance/source-policy.json"), value)
  end

  defp write_ledger!(root, entries) do
    write_json!(Path.join(root, "provenance/extracted-files.json"), %{
      "version" => 1,
      "entries" => entries
    })
  end

  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value))

  defp authorization_flags do
    ~w(public_source_copying_allowed copyright_terms_recorded license_terms_recorded notice_terms_recorded)
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
