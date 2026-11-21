#!/usr/bin/env python3
"""Verify the Rust gateway's HTTP body staging reservations and crash cleanup."""
import argparse
from contextlib import ExitStack, closing, contextmanager
import http.client
import json
from pathlib import Path
import signal
import socket
import struct
import tempfile
import threading
import time

from compare import ledger, synthetic_upstream
from verify_protocol import TOKEN, dump_gateway_failure, start, stop
from verify_upstream_zstd import MIB, Provider, configuration, wire

PATH = "/v1/responses"
DECLARED = 62 * MIB
MARKER = "synthetic-staging-marker"
PREFIX = b'{"input":"' + MARKER.encode() + b"x" * (256 * 1024)


def begin_upload(port, sockets):
    peer = socket.create_connection(("127.0.0.1", port), timeout=3)
    try:
        peer.sendall((f"POST {PATH} HTTP/1.1\r\nHost: localhost\r\n"
                      f"Authorization: Bearer {TOKEN}\r\nContent-Type: application/json\r\n"
                      f"Content-Length: {DECLARED}\r\nExpect: 100-continue\r\n"
                      "Connection: close\r\n\r\n").encode())
        with peer.makefile("rb") as response:
            fields = response.readline(1024).split()
            assert len(fields) >= 2 and fields[0] == b"HTTP/1.1", "Missing HTTP/1.1 status"
            status = int(fields[1])
            headers = http.client.parse_headers(response)
            if status != 100:
                assert status == 503, f"Expected staging capacity refusal, received {status}"
                length = int(headers["Content-Length"])
                assert 0 < length < 4096
                error = json.loads(response.read(length))["error"]["code"]
                assert error == "capacity_exhausted", error
                peer.close()
                return None
        # Hyper sends 100 only when the application first polls the body, after reservation.
        peer.sendall(PREFIX)
        return sockets.enter_context(peer)
    except BaseException:
        peer.close()
        raise


def saturate(port, sockets):
    uploads = [begin_upload(port, sockets) for _ in range(3)]
    assert all(peer is not None for peer in uploads), "Expected three staging reservations"
    assert begin_upload(port, sockets) is None, "Fourth upload exceeded the staging budget"
    return uploads


def replace_reset_upload(peer, port, sockets):
    peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    peer.close()
    deadline = time.monotonic() + 3
    while begin_upload(port, sockets) is None:
        assert time.monotonic() < deadline, "Client reset failed to return the staging reservation"
        time.sleep(0.02)
    assert begin_upload(port, sockets) is None, "Replacement upload did not charge the staging budget"


def stage_request(port, request):
    with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=8)) as connection:
        connection.request("POST", PATH, wire(request), {
            "Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json",
        })
        response = connection.getresponse()
        assert response.status == 200, f"Restarted staged upload returned {response.status}"
        assert json.loads(response.read(8192))["status"] == "completed"


def assert_private_output(output):
    assert TOKEN.encode() not in output, "Gateway logged the synthetic bearer token"
    assert MARKER.encode() not in output, "Gateway logged the synthetic body marker"


@contextmanager
def gateway(binary, config, root):
    process, ports = start(binary, config, root, http_body_staging=True)
    process.gateway_redactions += (MARKER,)
    try:
        yield process, ports["data"]
    except BaseException:
        if not process.stdout.closed:
            dump_gateway_failure(process)
        raise
    finally:
        if not process.stdout.closed:
            stop(process)


def verify(binary, root, provider):
    config = root / "identity.json"
    settings = configuration(provider, "off", "codex-subscription", 8 * MIB)
    settings["models"][0].update(inputMicrosPerMillion=1_000_000, outputMicrosPerMillion=1_000_000)
    config.write_text(json.dumps(settings), encoding="utf-8")
    config.chmod(0o600)
    request = dict(model="synthetic-order", input=MARKER + "y" * (9 * MIB), stream=False)
    provider.case, provider.calls, provider.errors = "ok", [], []
    provider.expected = wire(dict(request, input=[dict(role="user", content=request["input"])],
                                  stream=True, store=False))
    provider.streaming, provider.measure = True, False
    provider.started, provider.read_done = threading.Event(), threading.Event()
    state = root / "state"
    database = state / "core.sqlite"

    with gateway(binary, config, root) as (process, port):
        with ExitStack() as sockets:
            known_names = set(state.iterdir())
            first, *_ = saturate(port, sockets)
            replace_reset_upload(first, port, sockets)
            assert set(state.iterdir()) <= known_names, "An in-progress upload left a named file"
            assert not provider.calls, "An incomplete upload reached the synthetic provider"
            process.kill()
            assert process.wait(timeout=5) == -signal.SIGKILL
        assert set(state.iterdir()) <= known_names, "A staged file survived SIGKILL"
        ledger(database, 0)
        assert_private_output(process.stdout.read())

    with gateway(binary, config, root) as (process, port):
        stage_request(port, request)
        with ExitStack() as sockets:
            saturate(port, sockets)
            assert set(state.iterdir()) <= known_names, "Restart exposed a named staging file"
        assert provider.calls == ["identity"] and not provider.errors, (provider.calls, provider.errors)
        output = stop(process, drain_stdout=process.stdout.read)
        assert process.returncode == 0, "Restarted gateway failed to shut down cleanly"
        assert_private_output(output)
        ledger(database, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    binary = parser.parse_args().binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="codexone-rust-http-staging-") as temporary:
        with synthetic_upstream(Provider) as provider:
            verify(binary, Path(temporary), provider)
    print("PASS: HTTP staging capacity, reset, SIGKILL cleanup, restart, and exactly one settled upload")


if __name__ == "__main__":
    main()
