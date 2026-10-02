#!/usr/bin/env python3
"""Exact SketchyBar arguments for synthetic states, injected time and stub commands."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

plugin = str(Path("contrib/sketchybar/fromo.sh").resolve())
with tempfile.TemporaryDirectory(prefix="fromo-bar-") as root:
    root = Path(root)
    commands = root / "bin"
    commands.mkdir()
    recorder = '#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n'
    for name, content in [("sketchybar", recorder), ("fromo", recorder), ("date", '#!/bin/sh\nprintf "1000\\n"\n')]:
        path = commands / name
        path.write_text(content)
        path.chmod(0o755)
    state_file = root / "state/fromo/state.json"
    state_file.parent.mkdir(parents=True)
    env = dict(os.environ, HOME=str(root), XDG_STATE_HOME=str(root / "state"),
               PATH=str(commands) + ":" + os.environ["PATH"], NAME="fromo", SENDER="routine", BUTTON="left")
    base = dict(pid=os.getpid(), ends_at=1122, ended_at=900, remaining=750,
                task="Pushups", break_kind="short", lunch={"ends_at": 4600}, in_meeting=False)

    def render(state):
        state_file.write_text(json.dumps(state))
        result = subprocess.run(["sh", plugin], env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    cases = [
        ("ready", "Ready", "󰔛", "0xffa6adc8"),
        ("work", "Working ~ 02:02", "󰔛", "0xfff38ba8"),
        ("work_done", "Break time ~ +01:40", "󰀪", "0xfffab387"),
        ("break", "Pushups ~ 02:02", "󰅶", "0xffa6e3a1"),
        ("break_done", "Did Pushups? ~ +01:40", "󰀪", "0xfffab387"),
        ("paused", "Paused ~ 12:30", "󰏤", "0xff7f849c"),
        ("lunch", "Lunch ~ 60:00", "󰔉", "0xfff9e2af"),
    ]
    for phase, label, icon, color in cases:
        state = dict(base, phase=phase)
        expected = ["--set", "fromo", "drawing=on", "label=" + label, "icon=" + icon,
                    "icon.color=0xff121219", "label.color=0xffECEFF4",
                    "background.drawing=off", "icon.background.drawing=on", "icon.background.color=" + color,
                    "label.background.drawing=on", "label.background.color=0xff3C3E4F", "label.drawing=on"]
        assert render(state) == expected, (phase, render(state))
        meeting_label = label.split(" ~ ")[-1] if " ~ " in label else ""
        expected[3] = "label=" + meeting_label
        if not meeting_label:
            expected[10] = "label.background.drawing=off"
            expected[-1] = "label.drawing=off"
        assert render(dict(state, in_meeting=True)) == expected
    assert "icon.background.color=0xff94e2d5" in render(dict(base, phase="break", break_kind="long"))
    assert render(dict(base, phase="break", task=None))[3] == "label=Break ~ 02:02"
    assert render(dict(base, phase="break_done", task=None))[3] == "label=Break over ~ +01:40"
    assert render(dict(base, phase="work", ends_at=1))[3] == "label=Working ~ 00:00"
    assert render(dict(base, phase="break", task="A, B \"C\""))[3] == 'label=A, B "C" ~ 02:02'
    hidden = ["--set", "fromo", "drawing=off"]
    for state in [dict(base, phase="stopped"), dict(base, phase="work", pid=0),
                  dict(base, phase="work", pid=2147483647), dict(base, phase="unknown"),
                  dict(base, phase="work", ends_at=None)]:
        assert render(state) == hidden
    for text in ["{broken", "{}"]:
        state_file.write_text(text)
        assert json.loads(subprocess.check_output(["sh", plugin], env=env)) == hidden
    state_file.unlink()
    assert json.loads(subprocess.check_output(["sh", plugin], env=env)) == hidden
    for button, verb in [("left", "next"), ("right", "toggle")]:
        click = dict(env, SENDER="mouse.clicked", BUTTON=button)
        assert json.loads(subprocess.check_output(["sh", plugin], env=click)) == [verb]

print("SketchyBar exact-argument fixtures passed")
