#!/usr/bin/env python3
"""Check Rust native Images settlement when a real downstream socket stops reading."""
import argparse
from contextlib import closing
import http.client
import json
from pathlib import Path
import socket
import sqlite3
import struct
import tempfile
import time

from compare import TOKEN, fixture, request, running_gateway
from verify_images import PNG, Provider, native_body

PATH = "/v1/images/generations"
EXECUTION_SECONDS = 3
BLOCKED_REQUEST = {"prompt": "synthetic blocked delivery"}
EXPECTED_USAGE = {
    "images": 1,
    "imageInputTokens": 2,
    "imageOutputTokens": 3,
    "imageInputTextTokens": 1,
    "imageInputImageTokens": 1,
    "estimatedMicros": 13,
}


class Upstream(Provider):
    def do_POST(self):
        incoming = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.server.guard:
            self.server.calls += 1

        if (self.path != "/backend-api/codex/images/generations"
                or incoming.get("model") != "synthetic-image"
                or incoming.get("prompt") not in (BLOCKED_REQUEST["prompt"], "synthetic")):
            self.send_error(400)
            return

        body = native_body("synthetic")
        if incoming["prompt"] == BLOCKED_REQUEST["prompt"]:
            # Keep the image and its trusted usage identical across both failure cases. An
            # opaque field makes the JSON frame larger than the loopback socket's buffers.
            result = json.loads(body)
            result["future"] = "x" * (12 * 1024 * 1024)
            body = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def configure_images(config_path):
    config = json.loads(config_path.read_text())
    config.update(
        executionTimeoutSeconds=EXECUTION_SECONDS,
        imageConcurrency=1,
        imageGeneration={
            "defaultModel": "synthetic-image",
            "models": [{
                "id": "synthetic-image",
                "inputMicrosPerMillion": 2_000_000,
                "outputMicrosPerMillion": 3_000_000,
            }],
        },
    )
    config_path.write_text(json.dumps(config), encoding="utf-8")


def await_outcome(database, request_id):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        rows = database.execute(
            "SELECT state, usage_json, outcome_json FROM attempts WHERE request_id=?",
            (request_id,),
        ).fetchall()
        assert len(rows) == 1, "expected exactly one admission for the interrupted response"
        state, usage, outcome = rows[0]
        if outcome is not None:
            assert state == "settled", "trusted usage did not settle the attempt"
            observed = json.loads(usage)
            assert {key: observed.get(key) for key in EXPECTED_USAGE} == EXPECTED_USAGE, observed
            return json.loads(outcome)
        time.sleep(0.02)
    raise AssertionError("the connection ended without a durable delivery outcome")


def blocked_delivery(port, database, *, reset):
    payload = json.dumps(BLOCKED_REQUEST).encode()
    wire = (
        f"POST {PATH} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\n"
        f"Content-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n"
    ).encode() + payload
    with closing(socket.socket()) as client:
        client.settimeout(6)
        client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        client.connect(("127.0.0.1", port))
        client.sendall(wire)
        with closing(http.client.HTTPResponse(client)) as response:
            response.begin()
            assert response.status == 200, f"expected Images response head, got HTTP {response.status}"
            request_id = response.getheader("x-request-id")
            assert request_id and response.read(1) == b"{", "the JSON write did not start"
            if not reset:
                # Leave the socket open and unread while the gateway finalizes the attempt.
                return await_outcome(database, request_id)
            client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    return await_outcome(database, request_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    binary = parser.parse_args().binary.resolve(strict=True)

    with tempfile.TemporaryDirectory(prefix="codexone-rust-image-delivery-") as temporary:
        root = Path(temporary).resolve() / "gateway"
        with fixture(root, handler=Upstream) as (upstream, database, environment):
            configure_images(Path(environment["CODEXONE_IDENTITY_CONFIG"]))
            with running_gateway(binary, root, environment) as ports, closing(
                sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
            ) as ledger:
                for index, reset in enumerate((True, False)):
                    before = index * 2
                    outcome = blocked_delivery(ports["data"], ledger, reset=reset)
                    kind, failure = (
                        ("cancelled", "client_cancelled") if reset else ("failed", "deadline_exceeded")
                    )
                    assert (outcome["kind"], outcome["failure"]) == (kind, failure), outcome
                    elapsed = outcome["totalMilliseconds"]
                    if reset:
                        assert elapsed < EXECUTION_SECONDS * 1000, outcome
                    else:
                        # Reject finalization at the generic five-second idle-write timeout.
                        assert EXECUTION_SECONDS * 1000 <= elapsed < 5_000, outcome
                    assert upstream.calls == before + 1, "the interrupted image was replayed"

                    probe = request(ports["data"], PATH, {"prompt": "synthetic"})
                    assert probe["status"] == 200 and probe["body"]["data"][0]["b64_json"] == PNG, (
                        "the next image could not acquire the single Images permit"
                    )
                    assert upstream.calls == before + 2
                    assert ledger.execute("SELECT COUNT(*) FROM attempts").fetchone() == (before + 2,)
                    print(f"PASS: {failure} at {elapsed} ms, usage preserved, one dispatch, permit reusable")


if __name__ == "__main__":
    main()
