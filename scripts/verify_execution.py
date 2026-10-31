#!/usr/bin/env python3
"""Synthetic SQLite crash barriers. SIGKILL is not a power-loss test."""
import argparse
import os
from pathlib import Path
import selectors
import stat
import subprocess
import tempfile


def line(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        assert selector.select(timeout=10), "Execution probe timed out"
        result = process.stdout.readline().decode().strip()
        assert result and result != "probe_failed", "Execution probe failed"
        return result


def start(binary, path):
    process = subprocess.Popen([binary, str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env={"PATH": os.defpath}, bufsize=0, umask=0o022)
    try:
        assert line(process) == "ready"
        return process
    except BaseException:
        dispose(process)
        raise


def command(process, value):
    process.stdin.write((value + "\n").encode())
    return line(process)


def dispose(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=5)
    process.stdin.close()
    process.stdout.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = str(args.binary.resolve())
    for phase in ("before_intent", "after_intent", "after_binding", "after_settlement"):
        with tempfile.TemporaryDirectory(prefix="codexone-synthetic-") as directory:
            os.chmod(directory, 0o755)
            path = Path(directory) / "core.sqlite"
            process = start(binary, path)
            try:
                for suffix in ("", ".lock", "-wal", "-shm"):
                    assert stat.S_IMODE(Path(str(path) + suffix).stat().st_mode) == 0o600
                if phase != "before_intent":
                    assert command(process, "admit") == "admitted"
                if phase in ("after_binding", "after_settlement"):
                    assert command(process, "bind") == "bound"
                if phase == "after_settlement":
                    assert command(process, "finalize") == "settled"
                process.kill()
                assert process.wait(timeout=5) != 0
            finally:
                dispose(process)
            # Tighten legacy permissive files before any recovery/readiness work.
            for suffix in ("", ".lock", "-wal", "-shm"):
                candidate = Path(str(path) + suffix)
                if candidate.exists():
                    os.chmod(candidate, 0o644)
            recovered = start(binary, path)
            try:
                for suffix in ("", ".lock", "-wal", "-shm"):
                    assert stat.S_IMODE(Path(str(path) + suffix).stat().st_mode) == 0o600
                expected = "absent" if phase == "before_intent" else "settled" if phase == "after_settlement" else "unknown"
                assert command(recovered, "snapshot") == expected
                assert command(recovered, "resolve") == ("owned" if phase in ("after_binding", "after_settlement") else "absent")
                assert command(recovered, "capacity") == "accepted"  # Unknown accounting never globally blocks admission.
                if phase == "after_settlement":
                    assert command(recovered, "finalize") == "settled"
                    assert command(recovered, "snapshot") == "settled"
                assert command(recovered, "close") == "closed"
                assert recovered.wait(timeout=5) == 0
            finally:
                dispose(recovered)
            print(f"PASS: SIGKILL {phase}; durable ownership, exposure and settlement survive restart")


if __name__ == "__main__":
    main()
