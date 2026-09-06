#!/usr/bin/env python3
"""Verify the native candidate's checked-in license material against Cargo.lock."""
import hashlib
import json
from pathlib import Path
import tomllib

repo = Path(__file__).resolve().parents[2]
root = repo / "third_party/terminal-port"
manifest = json.loads((root / "manifest.json").read_text())
lock = tomllib.loads((repo / "native/terminal_port/Cargo.lock").read_text())
expected = {(p["name"], p["version"]): p for p in lock["package"] if "source" in p}
records = {(p["name"], p["version"]): p for p in manifest["packages"]}
assert manifest["schema_version"] == 1
assert len(records) == len(manifest["packages"])
assert records.keys() == expected.keys(), "License manifest differs from Cargo.lock"
count = 0
for identity, pin in expected.items():
    record = records[identity]
    assert record["crate_sha256"] == pin["checksum"], identity
    assert record["source"] == pin["source"], identity
    assert record["license_expression"] and record["licenses"], identity
    for item in record["licenses"]:
        path = root / item["path"]
        assert path.resolve().is_relative_to(root.resolve()) and not path.is_symlink(), item["path"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"], item["path"]
        count += 1
print(f"Verified {len(records)} locked crate records and {count} license texts.")
