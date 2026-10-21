#!/usr/bin/env python3
"""Credential-free executable HTTP, signal and startup-failure checks."""
import argparse
import http.client
import json
import os
import re
import selectors
import signal
import socket
import subprocess
import time
import tempfile
from pathlib import Path


def environment(**overrides):
    # Do not inherit account tokens or user-specific Codex settings.
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "CODEXONE_DATA_PORT": "0", "CODEXONE_ADMIN_PORT": "0", **overrides}


def release(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
    if process.stdout:
        process.stdout.close()


def request(port, method, path, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request(method, path, body=body, headers={"X-Synthetic-Secret": "synthetic-header-marker"})
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()


def assert_released(port):
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", port))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = str(args.binary.resolve())
    checked = subprocess.run([binary, "--check-config"], env=environment(), capture_output=True, text=True, timeout=10)
    assert checked.returncode == 0, checked.stderr
    assert json.loads(checked.stdout) == {"host": "127.0.0.1", "dataPort": 0, "adminPort": 0}
    bad = subprocess.run([binary, "--check-config"], env=environment(CODEXONE_DATA_PORT="private-invalid-value"), capture_output=True, text=True, timeout=10)
    assert bad.returncode == 78
    assert "private-invalid-value" not in bad.stderr
    print("PASS: configuration check and redacted invalid configuration")

    process = subprocess.Popen([binary], env=environment(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    ports = {}
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            output = b""
            deadline = time.monotonic() + 20
            while len(ports) < 2 and time.monotonic() < deadline:
                assert process.poll() is None, output.decode(errors="replace")
                for key, _ in selector.select(timeout=0.2):
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        continue
                    output += chunk
                    assert len(output) < 128 * 1024, "Unbounded startup output"
                    for name, port in re.findall(rb"LISTENING (data|admin) 127\.0\.0\.1:(\d+)", output):
                        ports[name.decode()] = int(port)
            assert len(ports) == 2, output.decode(errors="replace")
        for port in ports.values():
            assert request(port, "GET", "/health/live")[0] == 200
            status, body = request(port, "GET", "/health/ready")
            assert status == 503 and body["ready"] is False
        status, body = request(ports["admin"], "GET", "/api/system")
        assert status == 200 and body["service"] == "codexone"
        status, body = request(ports["data"], "POST", "/v1/responses", "{}")
        assert status == 503 and body["error"]["code"] == "gateway_not_configured"
        assert request(ports["data"], "POST", "/v1/responses", "x" * 5000)[0] == 413
        print("PASS: actual HTTP health, readiness, management contract, unavailable execution and body bound")
        for port in ports.values():
            assert request(port, "GET", "/synthetic-private-marker%0Asecond-line?secret=synthetic-query")[0] == 404
        assert request(ports["admin"], "POST", "/synthetic-private-marker", "synthetic-body-marker")[0] == 404
        partials = []
        keep_alive = http.client.HTTPConnection("127.0.0.1", ports["data"], timeout=3)
        try:
            for name, port in ports.items():
                partial = socket.create_connection(("127.0.0.1", port), timeout=3)
                partials.append(partial)
                path = "/v1/responses" if name == "data" else "/api/system"
                method = "POST" if name == "data" else "GET"
                partial.sendall(f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\n1".encode())
            keep_alive.request("GET", "/health/live")
            keep_alive.getresponse().read()
            connection = keep_alive.sock
            process.send_signal(signal.SIGTERM)
            assert process.wait(timeout=8) == 0
            assert connection is not None
            assert connection.recv(1) == b""
            for partial in partials:
                try:
                    drained = 0
                    while chunk := partial.recv(4096):
                        drained += len(chunk)
                        assert drained < 64 * 1024
                except ConnectionResetError:
                    pass
        finally:
            for partial in partials:
                partial.close()
            keep_alive.close()
        output += process.stdout.read()
        assert b"synthetic-private-marker" not in output
        assert b"synthetic-query" not in output
        assert b"synthetic-header-marker" not in output
        assert b"synthetic-body-marker" not in output
        for port in ports.values():
            assert_released(port)
        print("PASS: SIGTERM closes idle and incomplete requests, exits and releases both ports")
    finally:
        release(process)

    # A failure in one listener must stop the peer, with no orphan process.
    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", 0))
        occupied.listen()
        failed = subprocess.Popen([binary], env=environment(CODEXONE_ADMIN_PORT=str(occupied.getsockname()[1])), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            output, _ = failed.communicate(timeout=10)
            assert failed.returncode != 0
            for port in re.findall(rb"LISTENING data 127\.0\.0\.1:(\d+)", output):
                assert_released(int(port))
        finally:
            release(failed)
    print("PASS: partial startup failure terminates and releases the peer listener")

    # Real gateway startup holds the same instance lock as maintenance and recovers before listening.
    with tempfile.TemporaryDirectory(prefix="codexone-state-") as directory:
        configured = subprocess.Popen([binary], env=environment(CODEXONE_DATA_DIRECTORY=directory), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        configured_ports = {}
        try:
            startup_output = b""
            deadline = time.monotonic() + 15
            with selectors.DefaultSelector() as selector:
                selector.register(configured.stdout, selectors.EVENT_READ)
                while len(configured_ports) < 2 and time.monotonic() < deadline:
                    assert configured.poll() is None, "Configured gateway exited early"
                    for key, _ in selector.select(timeout=0.2):
                        startup_output += os.read(key.fd, 8192)
                        assert len(startup_output) < 128 * 1024
                        for name, port in re.findall(rb"LISTENING (data|admin) 127\.0\.0\.1:(\d+)", startup_output):
                            configured_ports[name.decode()] = int(port)
            assert len(configured_ports) == 2
            _, report = request(configured_ports["admin"], "GET", "/api/system")
            assert report["ready"] is False
            assert next(item for item in report["checks"] if item["name"] == "execution_store")["ready"] is True
            locked = subprocess.run([binary], env=environment(CODEXONE_DATA_DIRECTORY=directory), capture_output=True, timeout=10)
            assert locked.returncode != 0 and b"LISTENING" not in locked.stdout
            assert directory.encode() not in locked.stdout + locked.stderr
            configured.terminate()
            assert configured.wait(timeout=8) == 0
            for port in configured_ports.values():
                assert_released(port)
        finally:
            release(configured)
        # Lock is released on normal shutdown; persisted initialization is reusable.
        recovered = subprocess.Popen([binary], env=environment(CODEXONE_DATA_DIRECTORY=directory), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(recovered.stdout, selectors.EVENT_READ)
                assert selector.select(timeout=15)
                assert b"LISTENING" in os.read(recovered.stdout.fileno(), 8192)
        finally:
            release(recovered)
    print("PASS: configured SQLite startup, redacted lock rejection, shutdown and reopen")


if __name__ == "__main__":
    main()
