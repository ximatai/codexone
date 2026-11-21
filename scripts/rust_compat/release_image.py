#!/usr/bin/env python3
"""Run a synthetic HTTP and maintenance smoke test against a local amd64 image."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import hashlib
from http.client import HTTPConnection
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

from compare import TOKEN, Upstream, health, json_object, require, synthetic_upstream

DATA_PORT = 18080
ADMIN_PORT = 18081
PROVIDER_PORT = 18082
WORKERS = 8
REQUESTS = 32
DATA = "/var/lib/codexone"


def exercise():
    class Provider(Upstream):
        def do_POST(self):
            with self.server.guard:
                self.server.active += 1
                self.server.peak = max(self.server.peak, self.server.active)
            try:
                time.sleep(0.25)
                super().do_POST()
            finally:
                with self.server.guard:
                    self.server.active -= 1

    def turn(index):
        with closing(HTTPConnection("127.0.0.1", DATA_PORT, timeout=10)) as connection:
            body = json.dumps({
                "model": "synthetic-text",
                "input": f"synthetic turn {index}",
                "instructions": "x" * 65536,
                "stream": False,
            })
            connection.request("POST", "/v1/responses", body, {
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/json",
            })
            response = connection.getresponse()
            require(response.status == 200, f"Responses HTTP {response.status}")
            document = json_object(response.read(131072), "Responses")
            require(document.get("status") == "completed", "Responses did not complete")
            return document["id"]

    health({"data": DATA_PORT, "admin": ADMIN_PORT})
    with closing(HTTPConnection("127.0.0.1", ADMIN_PORT, timeout=5)) as connection:
        connection.request("GET", "/")
        reply = connection.getresponse()
        markup = reply.read(65536)
        script = re.search(rb'<script[^>]+src="(/assets/[^"]+\.js)"', markup)
        require(reply.status == 200 and script, "SPA entry point is missing")
        connection.request("GET", script[1].decode())
        asset = connection.getresponse()
        require(asset.status == 200 and asset.read(1), "SPA bundle is missing")

    with synthetic_upstream(Provider, port=PROVIDER_PORT) as provider:
        provider.active = provider.peak = 0
        started = time.monotonic()
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            ids = list(pool.map(turn, range(REQUESTS)))
        elapsed = time.monotonic() - started
        require(len(set(ids)) == provider.calls == REQUESTS, "Responses were replayed or lost")
        require(provider.peak > 1, "Fixture did not exercise concurrent upstream requests")
        return {"requests": REQUESTS, "clientWorkers": WORKERS,
                "peakConcurrentUpstream": provider.peak, "workloadSeconds": round(elapsed, 3)}


def docker(*args, data=None):
    result = subprocess.run(["docker", *args], input=data, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"docker {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout.decode().strip()


def verify(image, harness):
    candidate = json.loads(docker("image", "inspect", image))[0]
    harness_id = json.loads(docker("image", "inspect", harness))[0]["Id"]
    require((candidate["Os"], candidate["Architecture"], candidate["Config"]["User"]) ==
            ("linux", "amd64", "10001:10001"), "Expected an amd64 non-root runtime")
    image = candidate["Id"]
    label = candidate["Config"]["Labels"]
    common = ["--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true"]
    runtime = ["--platform", "linux/amd64", "--network", "none", *common, "--memory", "768m",
               "--memory-swap", "768m", "--pids-limit", "128", "--cpus", "1",
               "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m,mode=1777"]
    name = f"codexone-image-probe-{uuid.uuid4().hex[:12]}"
    fixture = name + "-config"
    data = name + "-data"
    mounted_data = ["--mount", f"type=volume,src={data},dst={DATA}"]
    config = ["--mount", f"type=volume,src={fixture},dst=/run/codexone,readonly",
              "--env", "CODEXONE_IDENTITY_CONFIG=/run/codexone/identity.json"]
    identity = {
        "principal": "synthetic-principal", "keyID": "synthetic-key",
        "keySHA256": hashlib.sha256(TOKEN.encode()).hexdigest(),
        "namespace": "synthetic-provider", "identity": "synthetic-account",
        "reservedMicros": 10, "executionTimeoutSeconds": 10,
        "models": [{"id": "synthetic-text", "inputMicrosPerMillion": 1000000,
                    "outputMicrosPerMillion": 1000000}],
        "upstreamBaseURL": f"http://127.0.0.1:{PROVIDER_PORT}/v1",
    }
    try:
        docker("run", "--rm", "-i", *runtime,
               "--mount", f"type=volume,src={fixture},dst={DATA}",
               "--entrypoint", "/bin/sh", image, "-ec", "umask 077; cat > identity.json",
               data=json.dumps(identity).encode())
        environment = docker("run", "--rm", *runtime, *mounted_data, *config,
                             "--entrypoint", "/bin/sh", image, "-ec",
                             'test "$(id -u):$(id -g)" = 10001:10001; '
                             'test "$(stat -c %a:%u:%g .)" = 700:10001:10001; '
                             'test -s /etc/ssl/certs/ca-certificates.crt; '
                             'test -n "$(find /opt/codexone/licenses/rust -type f -print -quit)"; '
                             'test -n "$(find /opt/codexone/licenses/npm -type f -print -quit)"; '
                             'sqlite3 -version; getconf GNU_LIBC_VERSION; '
                             'cat /opt/release.json')
        sqlite, glibc, release = environment.splitlines()
        release = json.loads(release)
        require(release["revision"] == label["org.opencontainers.image.revision"] and
                release["version"] == label["org.opencontainers.image.version"], "Release metadata differs")
        require(int(docker("run", "--rm", *runtime, image, "--schema-version")) ==
                release["schemaVersion"], "Image and binary schema versions differ")
        docker("run", "--rm", *runtime, *mounted_data, *config, image, "--check-config")

        started = time.monotonic()
        docker("run", "-d", "--name", name, *runtime, *mounted_data, *config, image)
        health_command = candidate["Config"]["Healthcheck"]["Test"]
        require(health_command[0] == "CMD-SHELL", "Expected the shell health probe")
        while True:
            result = subprocess.run(["docker", "exec", name, "sh", "-ec", health_command[1]],
                                    timeout=5, capture_output=True)
            if result.returncode == 0:
                break
            require(time.monotonic() - started < 20, "Image did not become live in 20 seconds")
            time.sleep(0.05)

        startup = time.monotonic() - started
        baseline = int(docker("exec", name, "cat", "/sys/fs/cgroup/memory.current"))
        scripts = Path(__file__).resolve().parents[1]
        workload = json.loads(docker(
            "run", "--rm", "--network", f"container:{name}", *common, "--memory", "512m",
            "--pids-limit", "64", "--env", "PYTHONDONTWRITEBYTECODE=1",
            "--mount", f"type=bind,src={scripts},dst=/scripts,readonly",
            "--entrypoint", "python3", harness_id, "/scripts/rust_compat/release_image.py", "--inside"))
        time.sleep(1)
        idle, peak = map(int, docker("exec", name, "cat", "/sys/fs/cgroup/memory.current",
                                     "/sys/fs/cgroup/memory.peak").splitlines())
        docker("stop", "--time", "30", name)
        require(docker("inspect", name, "--format", "{{.State.ExitCode}} {{.State.OOMKilled}}") ==
                "0 false", "Gateway did not shut down gracefully")
        docker("run", "--rm", *runtime, *mounted_data, *config, image, "--backup", f"{DATA}/bundle")
        docker("run", "--rm", *runtime, *mounted_data, *config, image, "--verify-backup", f"{DATA}/bundle")
        attempts = docker("run", "--rm", *runtime, *mounted_data, "--entrypoint", "sqlite3",
                          image, "-readonly", f"{DATA}/core.sqlite",
                          "SELECT count(*) FROM attempts WHERE state = 'settled' AND usage_json IS NOT NULL")
        require(int(attempts) == REQUESTS, "Expected every request to settle durably")
        return {**release, **workload, "engineArchitecture": docker("info", "--format", "{{.Architecture}}"),
                "glibc": glibc, "maintenanceSQLite": sqlite.split()[0],
                "runToLiveSeconds": round(startup, 3),
                "cgroupMemoryCurrentBeforeBytes": baseline, "cgroupMemoryPeakBytes": peak,
                "cgroupMemoryCurrentAfterBytes": idle}
    finally:
        for args in (("rm", "-f", name), ("volume", "rm", fixture, data)):
            subprocess.run(["docker", *args], capture_output=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", help="already loaded amd64 runtime")
    parser.add_argument("--harness-image", help="already loaded image with Python 3")
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.inside:
        report = exercise()
    elif args.image and args.harness_image:
        report = verify(args.image, args.harness_image)
    else:
        parser.error("--image and --harness-image are required")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
