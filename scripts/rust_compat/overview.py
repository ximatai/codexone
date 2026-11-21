#!/usr/bin/env python3
"""Exercise the Rust overview WebSocket with a gated synthetic provider."""
import argparse
import base64
import concurrent.futures
from contextlib import closing
import http.client
import json
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

from compare import fixture, listener_ports, require, running_gateway
from usage import get, request
from verify_protocol import TOKEN, Upstream

PATH = "/api/overview/live"


class GatedUpstream(Upstream):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        response = {
            "id": "resp_synthetic-live", "object": "response", "model": "synthetic-text",
            "status": "in_progress", "output": [], "usage": None,
        }
        try:
            if not self.server.first.wait(8):
                return
            self.wfile.write(("data: " + json.dumps({"type": "response.created", "response": response})
                              + "\n\n").encode())
            self.wfile.flush()
            if not self.server.final.wait(8):
                return
            response.update(status="completed", usage={"input_tokens": 5, "output_tokens": 3})
            self.wfile.write(("data: " + json.dumps({"type": "response.completed", "response": response})
                              + "\n\ndata: [DONE]\n\n").encode())
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def turn(port):
    with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=15)) as connection:
        connection.request("POST", "/v1/responses",
                           json.dumps({"model": "synthetic-text", "input": "synthetic live turn", "stream": True}),
                           {"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"})
        reply = connection.getresponse()
        body = reply.read()
        require(reply.status == 200 and b"response.completed" in body, "synthetic turn did not finish")


class Socket:
    def __init__(self, port, browser, path=PATH):
        self.client = socket.create_connection(("127.0.0.1", port), timeout=8)
        self.stream = self.client.makefile("rb")
        self.sequence = 0
        self.epoch = None
        self.data = {}
        try:
            headers = {
                "Host": f"127.0.0.1:{port}", "Upgrade": "websocket", "Connection": "Upgrade",
                "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": base64.b64encode(secrets.token_bytes(16)).decode(),
                **browser,
            }
            self.client.sendall((f"GET {path} HTTP/1.1\r\n"
                                 + "".join(f"{name}: {value}\r\n" for name, value in headers.items())
                                 + "\r\n").encode())
            self.status = int(self.stream.readline().split()[1])
            while self.stream.readline() not in (b"\r\n", b""):
                pass
        except BaseException:
            self.close()
            raise

    def close(self):
        self.stream.close()
        self.client.close()

    def send_control(self, opcode, payload):
        mask = secrets.token_bytes(4)
        self.client.sendall(bytes([0x80 | opcode, 0x80 | len(payload)]) + mask
                            + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))

    def poll(self, deadline):
        self.client.settimeout(max(deadline - time.monotonic(), 0.01))
        header = self.stream.read(2)
        require(len(header) == 2, "socket closed before expected frame")
        opcode, length = header[0] & 15, header[1] & 127
        if length in (126, 127):
            length = struct.unpack(">H" if length == 126 else ">Q",
                                   self.stream.read(2 if length == 126 else 8))[0]
        require(length <= 1024 * 1024, "oversized server WebSocket frame")
        payload = self.stream.read(length)
        if opcode == 9:
            self.send_control(10, payload)
        elif opcode == 1:
            frame = json.loads(payload)
            require(frame["protocol"] == 1 and frame["sequence"] == self.sequence + 1, "invalid sequence")
            require(frame["kind"] == ("snapshot" if self.sequence == 0 else "update"), "invalid update kind")
            if self.sequence == 0:
                self.epoch = frame["epoch"]
                require(set(frame["sections"]) == {
                    "system", "inFlight", "daily", "keys", "accounts", "storage", "attention", "headroom",
                }, "incomplete initial snapshot")
                require(all("data" in source for source in frame["sections"].values()), "missing snapshot data")
            require(self.epoch == frame["epoch"], "epoch changed on a live connection")
            self.sequence += 1
            for key, section in frame["sections"].items():
                if "data" in section:
                    self.data[key] = section["data"]
        elif opcode == 8:
            self.send_control(8, payload)
            return int.from_bytes(payload[:2], "big")
        return None

    def until(self, condition):
        deadline = time.monotonic() + 8
        while not condition(self.data):
            require(time.monotonic() < deadline, "expected overview update did not arrive")
            require(self.poll(deadline) is None, "upgrade closed before expected update")

    def expect_close(self, code):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            actual = self.poll(deadline)
            if actual is not None:
                require(actual == code, f"expected close {code}, received {actual}")
                return
        raise AssertionError(f"missing close frame {code}")


def log_in(port, token):
    browser = {"Origin": f"http://127.0.0.1:{port}", "Sec-Fetch-Site": "same-origin"}
    status, body, cookie = request(port, "/api/session", {**browser, "Content-Type": "application/json"},
                                   {"username": "admin", "secret": token})
    require(status == 200 and cookie, "session login failed")
    return {**browser, "Cookie": cookie.split(";", 1)[0]}, body["csrf"]


def run(candidate):
    with tempfile.TemporaryDirectory(prefix="codexone-overview-") as work:
        with fixture(Path(work) / "case") as (upstream, database, env):
            upstream.RequestHandlerClass = GatedUpstream
            upstream.first = threading.Event()
            upstream.final = threading.Event()
            root = database.parent.parent
            token = "synthetic-" + secrets.token_hex(24)
            secret = root / "admin-token"
            secret.write_text(token, encoding="utf-8")
            secret.chmod(0o600)
            env["CODEXONE_ADMIN_TOKEN_FILE"] = str(secret)
            identity = Path(env["CODEXONE_IDENTITY_CONFIG"])
            configuration = json.loads(identity.read_text())
            configuration["executionTimeoutSeconds"] = 15
            identity.write_text(json.dumps(configuration))
            with tempfile.TemporaryFile(dir=root) as output:
                gateway = subprocess.Popen([candidate], env=env, cwd=root, stdin=subprocess.DEVNULL,
                                           stdout=output, stderr=subprocess.STDOUT)
                try:
                    ports = listener_ports(gateway, output)
                    port = ports["admin"]
                    browser, csrf = log_in(port, token)
                    for path, headers, expected in [
                        (PATH + "?query=1", browser, 400),
                        (PATH, {**browser, "Origin": "http://127.0.0.1:1"}, 403),
                        (PATH, {**browser, "Authorization": f"Bearer {token}"}, 401),
                    ]:
                        with closing(Socket(port, headers, path)) as denied:
                            require(denied.status == expected, f"expected handshake denial {expected}")
                    with closing(Socket(port, browser)) as viewer, closing(Socket(port, browser)) as peer:
                        require(viewer.status == peer.status == 101, "browser upgrade failed")
                        viewer.until(lambda data: bool(data.get("storage")))
                        with closing(Socket(port, browser)) as overflow:
                            require(overflow.status == 429, "per-session limit not enforced")
                        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                            result = pool.submit(turn, ports["data"])
                            try:
                                viewer.until(lambda data: any(row.get("hasFirstEvent") is False
                                             for row in data["inFlight"]["rows"]))
                                upstream.first.set()
                                viewer.until(lambda data: any(row.get("hasFirstEvent") is True
                                             for row in data["inFlight"]["rows"]))
                                upstream.final.set()
                                viewer.until(lambda data: not data["inFlight"]["rows"]
                                             and data["daily"]["buckets"][-1]["requests"] == 1)
                                result.result(timeout=3)
                            finally:
                                upstream.first.set()
                                upstream.final.set()
                        with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=5)) as connection:
                            connection.request("DELETE", "/api/session",
                                               headers={**browser, "X-Codexone-CSRF": csrf})
                            require(connection.getresponse().status == 200, "logout failed")
                        viewer.expect_close(1008)
                        peer.expect_close(1008)
                    browser, _ = log_in(port, token)
                    with closing(Socket(port, browser)) as viewer:
                        require(viewer.status == 101, "upgrade before shutdown failed")
                        viewer.until(lambda data: bool(data.get("storage")))
                        gateway.terminate()
                        viewer.expect_close(1001)
                    require(gateway.wait(timeout=8) == 0, "gateway shutdown did not drain")
                finally:
                    upstream.first.set()
                    upstream.final.set()
                    if gateway.poll() is None:
                        gateway.kill()
                        gateway.wait(timeout=3)
    print("PASS: overview snapshot, in-flight/first-event/settlement updates, strict upgrade, per-session bound, logout and shutdown")


def native_clients(candidate):
    with tempfile.TemporaryDirectory(prefix="codexone-overview-native-") as work:
        with fixture(Path(work) / "case") as (_, database, env):
            root = database.parent.parent
            token = "synthetic-" + secrets.token_hex(24)
            secret = root / "admin-token"
            secret.write_text(token, encoding="utf-8")
            secret.chmod(0o600)
            env["CODEXONE_ADMIN_TOKEN_FILE"] = str(secret)
            identity = Path(env["CODEXONE_IDENTITY_CONFIG"])
            configuration = json.loads(identity.read_text())
            configuration["upstreamTransport"] = "websocket"
            identity.write_text(json.dumps(configuration))
            with tempfile.TemporaryFile(dir=root) as output:
                gateway = subprocess.Popen([candidate], env=env, cwd=root, stdin=subprocess.DEVNULL,
                                           stdout=output, stderr=subprocess.STDOUT)
                try:
                    ports = listener_ports(gateway, output)
                    browser, _ = log_in(ports["admin"], token)
                    with closing(Socket(ports["admin"], browser)) as viewer:
                        require(viewer.status == 101, "overview upgrade failed")
                        viewer.until(lambda data: data.get("inFlight", {}).get("clients") == [])
                        headers = {"Authorization": f"Bearer {TOKEN}"}
                        with closing(Socket(ports["data"], headers, "/v1/responses")) as native:
                            require(native.status == 101, "native client upgrade failed")
                            viewer.until(lambda data: any(
                                row["keyID"] == "synthetic-key" and row["count"] == 1
                                for row in data["inFlight"]["clients"]
                            ))
                        viewer.until(lambda data: data["inFlight"]["clients"] == [])
                finally:
                    gateway.terminate()
                    try:
                        gateway.wait(timeout=8)
                    finally:
                        if gateway.poll() is None:
                            gateway.kill()
                            gateway.wait(timeout=3)
    print("PASS: authenticated native WebSocket registers under its key and unregisters on socket close")


def resources(candidate):
    require(sys.platform == "linux", "the live resource sampler requires Linux")
    storage = "/api/runtime/storage"
    with tempfile.TemporaryDirectory(prefix="codexone-overview-resources-") as work:
        root = Path(work) / "case"
        with fixture(root) as (_, _, env):
            token = "synthetic-" + secrets.token_hex(24)
            secret = root / "admin-token"
            secret.write_text(token, encoding="utf-8")
            secret.chmod(0o600)
            env["CODEXONE_ADMIN_TOKEN_FILE"] = str(secret)
            headers = {"Authorization": f"Bearer {token}"}
            with running_gateway(candidate, root, env) as ports:
                port = ports["admin"]
                # Let two independent samples accumulate before the first admin request.
                time.sleep(31)
                deadline = time.monotonic() + 5
                history = get(port, storage, headers)["resources"]
                while len(history) < 2 and time.monotonic() < deadline:
                    time.sleep(0.1)
                    history = get(port, storage, headers)["resources"]
                require(len(history) == 2, "resource sampling did not run without viewers")
                first, second = history
                require(29 <= second["unixSeconds"] - first["unixSeconds"] <= 36,
                        "unexpected resource sample cadence")
                for sample in history:
                    for field in ("processResidentBytes", "hostTotalBytes", "diskAvailableBytes"):
                        require(sample[field] > 0, f"missing Linux resource {field}")
                    require(0 <= sample["hostAvailableBytes"] <= sample["hostTotalBytes"]
                            and sample["hostLoadAverage1m"] >= 0, "invalid Linux host metrics")
                require("hostCPUPercent" not in first and 0 <= second["hostCPUPercent"] <= 100,
                        "CPU requires consecutive Linux counter samples")
                browser, _ = log_in(port, token)
                with closing(Socket(port, browser)) as viewer:
                    require(viewer.status == 101, "resource overview upgrade failed")
                    viewer.until(lambda data: "resources" in data.get("storage", {}))
                    require(viewer.data["storage"]["resources"] == history,
                            "HTTP and WebSocket resource snapshots differ")

            env["CODEXONE_ADMIN_LIVE"] = "off"
            with running_gateway(candidate, root, env) as ports:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    restarted = get(ports["admin"], storage, headers)["resources"]
                    if restarted:
                        break
                    time.sleep(0.05)
                require(len(restarted) == 1 and "hostCPUPercent" not in restarted[0]
                        and restarted[0]["unixSeconds"] > first["unixSeconds"],
                        "restart kept old resource history or HTTP-only mode did not sample")
    print("PASS: Linux resource DTO over HTTP and WebSocket, no-viewer sampling and restart")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=lambda arg: Path(arg).resolve(), required=True)
    parser.add_argument("--resources", action="store_true", help="also check live Linux resource readings")
    args = parser.parse_args()
    run(args.candidate)
    native_clients(args.candidate)
    if args.resources:
        resources(args.candidate)
