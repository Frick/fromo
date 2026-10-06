#!/usr/bin/env python3
"""Deterministic CLI/socket integration. All data is synthetic and isolated in temp XDG paths."""
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/fromo").resolve())
NOW = 1790852400


def run(env, *args, code=0):
    result = subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=5)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout


def launch(env):
    process = subprocess.Popen(
        [binary, "engine", "--headless", "--now", str(NOW)],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
    )
    # Readiness is an explicit protocol event, never a sleep or a wall-clock test.
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = b""
    listening = False
    while not listening:
        assert selector.select(timeout=10), "headless readiness timed out"
        chunk = os.read(process.stdout.fileno(), 4096)
        assert chunk, process.stderr.read()
        pending += chunk
        while b"\n" in pending:
            line, pending = pending.split(b"\n", 1)
            if json.loads(line).get("effect") == "listening":
                listening = True
    selector.close()
    return process


def stop(process):
    process.send_signal(signal.SIGTERM)
    stdout, stderr = process.communicate(timeout=5)
    assert process.returncode == 0, stderr
    return stdout


with tempfile.TemporaryDirectory(prefix="fromo-") as root:
    env = dict(os.environ, HOME=root, XDG_CONFIG_HOME=root + "/c", XDG_STATE_HOME=root + "/s", TZ="UTC")
    state_path = Path(root) / "s/fromo/state.json"
    config_path = Path(root) / "c/fromo/config.toml"
    socket_path = str(Path(root) / "s/fromo/fromo.sock")
    for command in ["start", "break", "pause", "resume", "toggle", "next", "restart", "extend", "end-break",
                    "reset", "lunch", "not-today", "end-day", "answer", "status", "stats", "config", "settings", "engine"]:
        run(env, command, "--help")
    assert run(env, "status").strip() == "not running"
    assert json.loads(run(env, "status", "--json")) == {"running": False}
    run(env, "start", code=2)
    run(env, "status", "--debug", code=2)
    run(env, "answer", code=64)
    run(env, "answer", "--did", "Other", code=64)
    run(env, "extend", "-2", code=64)
    assert run(env, "config", "path").strip() == str(config_path)
    run(env, "config", "validate")
    config_path.parent.mkdir(parents=True)
    config_path.write_text('[timer]\nwork_minutes = -1\n')
    run(env, "config", "validate", code=3)
    run(env, "engine", "--headless", "--now", str(NOW), code=3)
    config_path.write_text('[timer]\nwork_minutes = 1\n')

    process = launch(env)
    try:
        assert os.stat(socket_path).st_mode & 0o777 == 0o600
        debug = json.loads(run(env, "status", "--debug", "--json"))
        assert debug["phase"] == "ready" and debug["idle_seconds"] == 0
        assert not debug["camera_in_use"] and not debug["microphone_in_use"]
        assert "Nag eligible:" in run(env, "status", "--debug")
        before = state_path.read_bytes()
        run(env, "engine", "--headless", "--now", str(NOW), code=2)
        assert state_path.read_bytes() == before, "second instance wrote state"
        for payload, code in [(b'{broken\n', "usage"), (b'{"v":2,"cmd":"start"}\n', "usage")]:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(2)
                client.connect(socket_path)
                client.sendall(payload)
                assert json.loads(client.recv(4096))["code"] == code
        run(env, "start")
        state = json.loads(run(env, "status", "--json"))
        assert state["phase"] == "work" and state["ends_at"] == NOW + 60
        run(env, "start", code=1)
        run(env, "pause")
        run(env, "resume")
        run(env, "toggle")
        run(env, "restart")
        run(env, "extend", "2")
        assert json.loads(run(env, "status", "--json"))["ends_at"] == NOW + 180
        run(env, "lunch", "2")
        run(env, "lunch", "--end")
        run(env, "reset")
        run(env, "not-today")
        assert json.loads(run(env, "status", "--json"))["nags_off_until"] is not None
        run(env, "not-today", "--off")
        run(env, "settings", code=1)
        run(env, "answer", "--did", code=1)
        run(env, "end-day")
        assert json.loads(run(env, "status", "--json"))["day_closed_at"] == NOW
        run(env, "start")
        assert json.loads(run(env, "status", "--json"))["day_closed_at"] is None
    finally:
        stop(process)
    stopped = json.loads(state_path.read_text())
    assert stopped["phase"] == "stopped"
    assert stopped["stopped_phase"] == "work"
    assert run(env, "status").strip() == "not running"
    assert not Path(socket_path).exists()

    process = launch(env)
    try:
        assert json.loads(run(env, "status", "--json"))["phase"] == "work"
        run(env, "reset")
    finally:
        stop(process)
    stopped = json.loads(state_path.read_text())

    # Seed an expired synthetic work phase before launch, injecting a fixed clock.
    state = dict(stopped, phase="work", stopped_phase=None, started_at=NOW - 60,
                 ends_at=NOW, planned_seconds=60, ended_at=None, remaining=None,
                 paused_phase=None, date="2026-10-01")
    state_path.write_text(json.dumps(state))
    process = launch(env)
    try:
        assert json.loads(run(env, "status", "--json"))["phase"] == "work_done"
        run(env, "break")
        run(env, "end-break")
        run(env, "answer", "not a valid item", code=1)
        run(env, "answer", "--did", "--no-start")
        state = json.loads(run(env, "status", "--json"))
        assert state["phase"] == "ready" and state["rotation"]["short"]["name"] == "Squats"
    finally:
        stop(process)

    # A stale socket is reclaimed; a live socket is never removed.
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(socket_path)
    stale.close()
    process = launch(env)
    stop(process)
    assert not Path(socket_path).exists()
    logs = list((Path(root) / "s/fromo/log").glob("*.csv"))
    text = "".join(path.read_text() for path in logs)
    assert "completed" in text and "did_suggested" in text and "abandoned" in text

print("CLI / headless IPC integration passed")
