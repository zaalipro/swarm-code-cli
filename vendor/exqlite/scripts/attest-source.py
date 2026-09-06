#!/usr/bin/env python3
"""Fail before native compilation if pinned immutable SQLite/license inputs drift."""
import hashlib
import json
from pathlib import Path

def require(condition, message):
    if not condition:
        raise SystemExit("Source attestation failed: " + str(message))


fork = Path(__file__).resolve().parents[1]
manifest = json.loads((fork / "UPSTREAM.json").read_text())
expected = {
    "c_src/sqlite3.c": "87497ab605bedd0dbee27a209c1eeff8c89b229b13f921a7efdbb81a13f779fd",
    "c_src/sqlite3.h": "4ff81af4849acabc76fc8349abb926814395072617ca18e08800abf734ab7612",
}
require(manifest["version"] == "0.39.0", 'manifest["version"] == "0.39.0"')
require(manifest["fork_version"] == "0.39.0-swarm.1", 'manifest["fork_version"] == "0.39.0-swarm.1"')
require(manifest["commit"] == "266b34e46b20e1c48f497cb4fb338919c793efee", 'manifest["commit"] == "266b34e46b20e1c48f497cb4fb338919c793efee"')
require(manifest["pristine_sha256"]["c_src/sqlite3_nif.c"] == "c9e5565269829fa5ed4afccf1cb5d4cd3aa4b7ac3ed584503486cf8a64add819", 'manifest["pristine_sha256"]["c_src/sqlite3_nif.c"] == "c9e5565269829fa5ed4afccf1cb5d4cd3aa4b7ac3ed584503486cf8a64add819"')
for name, digest in expected.items():
    require(manifest["pristine_sha256"][name] == digest, 'manifest["pristine_sha256"][name] == digest')
    require(hashlib.sha256((fork / name).read_bytes()).hexdigest() == digest, name)
for name in ("LICENSE", "c_src/sqlite3ext.h"):
    require(hashlib.sha256((fork / name).read_bytes()).hexdigest() == manifest["pristine_sha256"][name], name)
mix = (fork / "mix.exs").read_text()
require('@version "0.39.0-swarm.1"' in mix, '\'@version "0.39.0-swarm.1"\' in mix')
require('make_precompiler: nil' in mix, "'make_precompiler: nil' in mix")
require('cc_precompiler' not in mix, "'cc_precompiler' not in mix")
require('make_precompiler_url' not in mix, "'make_precompiler_url' not in mix")
print("PASS pinned SQLite/license hashes, fork version, and disabled precompiler metadata")
