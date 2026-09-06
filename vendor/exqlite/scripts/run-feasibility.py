#!/usr/bin/env python3
"""Build/test the fork without Mix or shared artifact writes; own outputs in _build."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

FORK = Path(__file__).resolve().parents[1]
REPO = FORK.parents[1]
ROOT = REPO / "_build" / "vendor-exqlite-feasibility-script"
APPS = ("exqlite", "db_connection", "telemetry", "decimal", "ecto", "ecto_sql", "ecto_sqlite3", "jason")


def run(args, *, cwd=REPO, env=None, expect=0):
    print("+", " ".join(map(str, args)), flush=True)
    result = subprocess.run(list(map(str, args)), cwd=cwd, env=env)
    if result.returncode != expect:
        raise SystemExit(f"Expected exit {expect}, got {result.returncode}")


def prepare(destination):
    for app in APPS:
        # Only compiled input copies; never symlinks or original dependency writes.
        source = REPO / "_build" / "test" / "lib" / app / "ebin"
        if not source.is_dir():
            raise SystemExit(f"Missing compiled read-only input: {source}")
        shutil.copytree(source, destination / "lib" / app / "ebin", dirs_exist_ok=True)
    (destination / "lib/exqlite/priv").mkdir(exist_ok=True)
    app_file = destination / "lib/exqlite/ebin/exqlite.app"
    app_file.write_text(re.sub(r'\{vsn,"[^"]+"\}', '{vsn,"0.39.0-swarm.1"}', app_file.read_text()))


def main():
    if os.environ.get("EXQLITE_USE_SYSTEM"):
        raise SystemExit("EXQLITE_USE_SYSTEM is forbidden in this feasibility build")
    run([sys.executable, FORK / "scripts/attest-source.py"])
    erlang = subprocess.check_output(
        ["mise", "exec", "--", "erl", "-noshell", "-eval",
         'io:format("~s", [code:root_dir()]), halt().'], cwd=REPO, text=True)
    include = Path(erlang) / "usr/include"
    for mode in ("test", "prod"):
        destination = ROOT / mode
        prepare(destination)
        env = os.environ.copy()
        env.pop("EXQLITE_USE_SYSTEM", None)
        env.pop("SWARM_GUARD_TEST", None)
        env["MIX_ENV"] = mode
        env["SWARM_FEASIBILITY_ROOT"] = str(destination)
        if mode == "test":
            env["SWARM_GUARD_TEST"] = "1"
        run(["make", f"MIX_APP_PATH={destination / 'lib/exqlite'}",
             f"ERTS_INCLUDE_DIR={include}", f"ERL_EI_INCLUDE_DIR={include}"], cwd=FORK, env=env)
        run(["mise", "exec", "--", "elixirc", "--ignore-module-conflict", "-o",
             destination / "lib/exqlite/ebin", FORK / "lib/exqlite/sqlite3_nif.ex",
             FORK / "lib/exqlite/swarm_guard.ex"], env=env)
        tests = ("feasibility.exs", "ecto_compat.exs") if mode == "test" else ("production.exs",)
        for test in tests:
            run(["mise", "exec", "--", "elixir", FORK / "test/swarm_guard" / test], env=env)
    run(["make", "-n", "EXQLITE_USE_SYSTEM=1"], cwd=FORK, expect=2)
    run(["make", "-n", "MIX_ENV=prod", "SWARM_GUARD_TEST=1"], cwd=FORK, expect=2)
    print(json.dumps({"result": "passed", "output_root": str(ROOT),
                      "limits": "local fixture proof; copied adapter beams; no canonical pool"}))


if __name__ == "__main__":
    main()
