#!/usr/bin/env python3
"""Stats CLI integration over synthetic logs, with no running engine or real XDG reads."""
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/fromo").resolve())
with tempfile.TemporaryDirectory(prefix="fromo-stats-") as root:
    env = dict(os.environ, HOME=root, XDG_CONFIG_HOME=root + "/c", XDG_STATE_HOME=root + "/s", TZ="UTC")
    config = Path(root) / "c/fromo/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text("[timer]\ndaily_goal = 2\n")
    logs = Path(root) / "s/fromo/log"
    logs.mkdir(parents=True)

    def run(*args, code=0):
        result = subprocess.run([binary, "stats", *args], env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        return result

    options = ["--from", "2026-09-28", "--to", "2026-09-30"]
    empty = json.loads(run(*options, "--json").stdout)
    assert empty["completed"] == 0 and len(empty["days"]) == 3
    assert not (Path(root) / "s/fromo/state.json").exists()
    assert not (Path(root) / "s/fromo/fromo.sock").exists()
    with (logs / "2026-09-28.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["start", "end", "kind", "planned_seconds", "outcome", "suggested", "actual"])
        writer.writerows([
            ["2026-09-28T09:00:00Z", "2026-09-28T09:30:00Z", "work", 1800, "completed", "", ""],
            ["2026-09-28T10:00:00Z", "2026-09-28T10:25:00Z", "work", 1500, "completed", "", ""],
            ["2026-09-28T11:00:00Z", "2026-09-28T11:05:00Z", "work", 1500, "abandoned", "", ""],
            ["2026-09-28T09:30:00Z", "2026-09-28T09:35:00Z", "short_break", 300, "did_suggested", 'Task, "A"', 'Task, "A"'],
            ["2026-09-28T10:25:00Z", "2026-09-28T10:30:00Z", "short_break", 300, "did_other", "B", "Other"],
            ["2026-09-28T14:00:00Z", "2026-09-28T14:15:00Z", "long_break", 900, "unanswered", "Unanswered task", ""],
            ["2026-09-28T12:00:00Z", "2026-09-28T12:05:00Z", "unknown", 300, "unknown", "", ""],
            ["malformed"],
        ])
    before = (logs / "2026-09-28.csv").read_bytes()
    result = run(*options, "--json")
    report = json.loads(result.stdout)
    assert report["completed"] == 2 and report["abandoned"] == 1
    assert report["focus_seconds"] == 3300 and report["goal_met_days"] == 1
    assert report["compliance_percent"] == 50 and report["short_breaks"] == 2
    assert report["long_breaks"] == 1 and report["unanswered_breaks"] == 1 and report["answered_breaks"] == 2
    assert report["skipped_rows"] == 2 and len(result.stderr.splitlines()) == 1
    assert report["tasks"][1]["name"] == 'Task, "A"'
    assert [day["completed"] for day in report["days"]] == [2, 0, 0]
    assert "0h55m focus" in run(*options).stdout
    assert (logs / "2026-09-28.csv").read_bytes() == before
    for args in [["--today", "--week"], ["--month", *options], ["--from", "2026-09-28"],
                 ["--from", "2026-02-30", "--to", "2026-03-01"],
                 ["--from", "2026-10-02", "--to", "2026-10-01"]]:
        run(*args, code=64)
    config.write_text("[timer]\ndaily_goal = -1\n")
    run(*options, code=3)

print("Stats CLI synthetic-log integration passed")
