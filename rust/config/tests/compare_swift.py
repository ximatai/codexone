#!/usr/bin/env python3
"""Compare isolated, synthetic configuration checks with the pinned Swift CLI."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile


def write(path, value, mode=0o600):
    data = value if isinstance(value, bytes) else json.dumps(value).encode()
    path.write_bytes(data)
    path.chmod(mode)


def snapshot(root):
    return {
        str(path.relative_to(root)): (
            path.lstat().st_mode,
            os.readlink(path) if path.is_symlink()
            else path.read_bytes() if path.is_file()
            else None,
        )
        for path in root.rglob("*")
    }


def compare(reference, candidate, root, case, settings, expected, *args):
    env = {f"CODEXONE_{key}": str(value) for key, value in settings.items()}
    before = snapshot(root)
    outcomes = []
    for binary in (reference, candidate):
        run = subprocess.run(
            [binary, *args], env=env, cwd=root,
            capture_output=True, check=False, timeout=10,
        )
        outcomes.append((run.returncode, run.stdout, run.stderr))
        if snapshot(root) != before:
            raise AssertionError(f"{case}: a configuration command changed the fixture")
    if outcomes[0][0] != expected or outcomes[0] != outcomes[1]:
        # All inputs are fabricated. Avoid printing either implementation's full stderr
        # so the failure output is still safe if someone extends the fixtures.
        raise AssertionError(
            f"{case}: expected exit {expected}, Swift exited {outcomes[0][0]}, "
            f"Rust exited {outcomes[1][0]}, stdout matches={outcomes[0][1] == outcomes[1][1]}, "
            f"stderr matches={outcomes[0][2] == outcomes[1][2]}"
        )


def run_cases(reference, candidate, root, upstream):
    def check(case, settings, expected=0, *args):
        nonlocal cases
        compare(reference, candidate, root, case, settings, expected, *(args or ("--check-config",)))
        cases += 1

    cases = 0
    check("default", {})
    check("schema skips validation", {"DATA_PORT": "bad"}, 0, "--schema-version")
    check("unsupported argument combination", {}, 64, "--schema-version", "--check-config")
    check("ephemeral ports", {"DATA_PORT": 0, "ADMIN_PORT": 0})
    check("occupied port is not bound", {"DATA_PORT": upstream.getsockname()[1], "ADMIN_PORT": 0})

    for offset in ("-12:00", "+14:00", "-00:00"):
        check(f"business-day {offset}", {"BUSINESS_DAY_OFFSET": offset})
    check("private IPv6 listener", {"LISTEN_ADDRESS": "fd00::2", "ALLOWED_NETWORKS": "fc00::/7"})
    check("private IPv4 listener", {"LISTEN_ADDRESS": "100.64.0.2", "ALLOWED_NETWORKS": "100.64.0.99/10,::1/128"})
    for case, settings in {
        "business-day minutes": {"BUSINESS_DAY_OFFSET": "+05:30"},
        "business-day range": {"BUSINESS_DAY_OFFSET": "-13:00"},
        "public IP": {"LISTEN_ADDRESS": "203.0.113.1"},
        "noncanonical IP": {"LISTEN_ADDRESS": "010.0.0.1"},
        "public CIDR": {"ALLOWED_NETWORKS": "0.0.0.0/0"},
        "too many CIDRs": {"ALLOWED_NETWORKS": ",".join(["10.0.0.0/8"] * 65)},
        "ports conflict": {"DATA_PORT": 18081},
        "port syntax": {"DATA_PORT": "+40"},
        "admin port range": {"ADMIN_PORT": 65536},
        "relative data directory": {"DATA_DIRECTORY": "relative"},
        "staging without data": {"HTTP_BODY_STAGING": "on"},
        "identity without data": {"IDENTITY_CONFIG": "/example"},
        "web directory path": {"WEB_DIRECTORY": ""},
        "admin live toggle": {"ADMIN_LIVE": "true"},
        "master key without admin": {"DATA_DIRECTORY": root / "uncreated", "ACCOUNT_MASTER_KEY_FILE": "/example"},
    }.items():
        check(case, settings, 78)

    data_env = {"DATA_DIRECTORY": root / "uncreated"}
    check("data directory stays absent", data_env | {"HTTP_BODY_STAGING": "on"})
    backup = root / "backup"
    backup.mkdir(mode=0o700)
    check("backup directory", data_env | {"BACKUP_DIRECTORY": backup})
    backup.chmod(0o755)
    check("non-private backup", data_env | {"BACKUP_DIRECTORY": backup}, 78)
    backup.chmod(0o700)
    backup_link = root / "backup-link"
    backup_link.symlink_to(backup)
    check("symlink backup", data_env | {"BACKUP_DIRECTORY": backup_link}, 78)

    identity = root / "identity.json"
    login_key = "fictitious-login-secret-for-comparison"
    login_digest = hashlib.sha256(login_key.encode()).hexdigest()
    model = {"id": "example-model", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0}
    source = {"models": [model], "reservedMicros": 0}
    single = source | {
        "namespace": "example-namespace", "identity": "example-identity",
        "principal": "example-subject", "keyID": "example-key", "keySHA256": login_digest,
        "upstreamBaseURL": f"http://127.0.0.1:{upstream.getsockname()[1]}/v1",
    }
    single_env = data_env | {"IDENTITY_CONFIG": identity}
    write(identity, single)
    check("static single identity", single_env)
    write(identity, single | {"reservedMicros": 1.0})
    check("integral decimal", single_env)
    write(identity, json.dumps(single).encode().replace(b'"reservedMicros": 0', b'"reservedMicros": 1.0000000000000001'))
    check("integral double rounding", single_env)
    for encoding in ("utf-8-sig", "utf-16-le", "utf-16-be", "utf-32-le", "utf-32-be"):
        write(identity, json.dumps(single).encode(encoding))
        check(f"identity JSON encoding {encoding}", single_env)
    write(identity, b'{"reservedMicros": 0,' + json.dumps(single | {"reservedMicros": -1}).encode()[1:])
    check("first duplicate configuration field valid", single_env)
    write(identity, b'{"reservedMicros": -1,' + json.dumps(single).encode()[1:])
    check("first duplicate configuration field invalid", single_env, 1)
    write(identity, json.dumps(single).encode()[:-1] + b",}")
    check("trailing comma in identity JSON", single_env)
    write(identity, single | {"reservedMicros": 1.5})
    check("fractional decimal", single_env, 1)
    write(identity, single | {"reservedMicros": None})
    check("null required value", single_env, 1)
    write(identity, single | {"models": [model | {"metadata": True}]})
    check("ordinary unknown model field", single_env)
    image = model | {"id": "example-image", "hostModel": model["id"],
                     "sizePolicy": "flexible3840", "supportsTransparency": True}
    write(identity, single | {"imageGeneration": {"defaultModel": image["id"], "models": [image]}})
    check("image configuration", single_env)
    for key in ("upstream", "profileProvenance", "reasoningSettings"):
        write(identity, single | {"models": [model | {key: None}]})
        check(f"persisted-only field {key}", single_env, 1)
    for case, patch in {
        "unknown identity field": {"unexpected": 1},
        "pool-only upstream": {"upstreamBaseURL": "https://example.invalid/backend-api/codex"},
        "shortened loopback": {"upstreamBaseURL": "http://127.1:9000/v1"},
        "implicit loopback port": {"upstreamBaseURL": "http://127.0.0.1/v1"},
        "dot segments": {"upstreamBaseURL": single["upstreamBaseURL"].replace("/v1", "/a/../v1")},
        "insufficient first response budget": {"executionTimeoutSeconds": 2, "firstResponseTimeoutSeconds": 3},
        "invalid compression threshold": {"upstreamRequestCompression": "off", "upstreamZstdMinimumBytes": -1},
        "client fingerprint not ASCII": {"clientFingerprint": {"version": "示例"}},
        "duplicate models": {"models": [model, model]},
        "bad image catalog": {"imageGeneration": {"defaultModel": "bad", "models": [model]}},
    }.items():
        write(identity, single | patch)
        check(case, single_env, 1)

    write(identity, single)
    identity.chmod(0o644)
    check("non-private identity", single_env, 1)
    identity.chmod(0o600)
    link = root / "identity-link"
    link.symlink_to(identity)
    check("symlink identity", single_env | {"IDENTITY_CONFIG": link}, 1)
    link.unlink()
    os.link(identity, link)
    check("hard-linked identity", single_env, 1)
    link.unlink()
    os.mkfifo(link, mode=0o600)
    check("nonblocking FIFO rejection", single_env | {"IDENTITY_CONFIG": link}, 1)
    link.unlink()

    token = root / "upstream-token"
    write(token, b"example-upstream-token\n")
    subscription = single | {"upstreamBaseURL": "https://chatgpt.com/backend-api/codex"}
    write(identity, subscription)
    check("subscription requires token", single_env, 1)
    write(identity, subscription | {"upstreamTokenFile": str(token)})
    check("subscription reads but does not use token", single_env)
    write(token, b"bad token")
    check("invalid upstream token", single_env, 1)

    admin = root / "admin"
    admin_material = b"fictitious-example-admin-material"
    write(admin, admin_material)
    admin_env = data_env | {"ADMIN_TOKEN_FILE": admin}
    check("independent administrator", admin_env)
    write(admin, login_key.encode())
    write(identity, single)
    check("administrator cannot reuse single key", single_env | admin_env, 1)
    write(admin, admin_material)

    managed = {key: value for key, value in single.items() if key not in {"principal", "keyID", "keySHA256"}}
    write(identity, managed | {"managedKeys": True})
    check("managed identity without administrator", single_env, 78)
    check("managed identity", single_env | admin_env)
    check("trusted loopback origin", admin_env | {"ADMIN_PUBLIC_ORIGIN": "http://localhost:5179/"})
    check("trusted HTTPS origin", admin_env | {"ADMIN_PUBLIC_ORIGIN": "https://admin.example.invalid/"})
    check("LAN origin matches listener", admin_env | {"ADMIN_PUBLIC_ORIGIN": "http://[fd00::1]:8000", "LISTEN_ADDRESS": "fd00:0::1"})
    check("LAN origin without matching listener", admin_env | {"ADMIN_PUBLIC_ORIGIN": "http://10.0.0.1:80"}, 78)
    check("percent-encoded HTTPS host", admin_env | {"ADMIN_PUBLIC_ORIGIN": "https://%65xample.invalid"})
    check("invalid decoded HTTPS host", admin_env | {"ADMIN_PUBLIC_ORIGIN": "https://a%2fb"}, 1)
    check("malformed HTTPS origin", admin_env | {"ADMIN_PUBLIC_ORIGIN": "https://admin.example.invalid/path"}, 1)

    keyring = root / "master"
    active, old = "0123456789abcdef" * 4, "abcdef0123456789" * 4
    pool = root / "pool.json"
    pool_env = admin_env | {"ACCOUNT_MASTER_KEY_FILE": keyring, "ACCOUNT_POOL_CONFIG": pool}
    write(pool, source)
    write(keyring, active.encode())
    check("account pool with legacy master key", pool_env)
    write(keyring, {"format": 1, "active": active.upper(), "decryptOnly": [old]})
    check("account pool with rotating keyring", pool_env)
    write(keyring, b'{"format":1,' + json.dumps({"format": 2, "active": active, "decryptOnly": [old]}).encode()[1:])
    check("first duplicate keyring field", pool_env)
    write(keyring, json.dumps({"format": 1, "active": active, "decryptOnly": []}).encode()[:-1] + b",}")
    check("trailing comma in keyring JSON", pool_env)
    write(keyring, {"format": 1, "active": active, "decryptOnly": [active.upper()]})
    check("same master key in different case", pool_env, 78)
    write(keyring, admin_material)
    check("administrator cannot be master key", pool_env, 78)
    write(keyring, active.encode())
    check("pool and identity mutually exclusive", single_env | pool_env, 78)
    write(pool, source | {"managedKeys": True})
    check("identity field rejected in pool", pool_env, 1)

    profile = root / "profiles.json"
    profile_json = {
        "version": 1, "source": "synthetic", "revision": "a", "capturedAtUnixSeconds": 1,
        "clientVersions": ["1.0.0"],
        "models": [{"id": model["id"], "upstream": {"base_instructions": "Synthetic profile."}}],
    }
    write(pool, source | {"modelProfilesFile": str(profile)})
    write(profile, profile_json)
    check("offline model profile", pool_env)
    write(profile, json.dumps(profile_json).encode("utf-8-sig"))
    check("UTF-8 BOM model profile", pool_env)
    write(profile, json.dumps(profile_json).encode("utf-16-le"))
    check("UTF-16 model profile", pool_env)
    write(profile, profile_json | {"capturedAtUnixSeconds": 9_000_000_000})
    check("future model profile", pool_env, 1)
    write(profile, profile_json | {"models": [{"id": "absent", "catalog": {"baseInstructions": "Example"}}]})
    check("missing configured model in profile", pool_env, 1)

    web = root / "web"
    (web / "assets").mkdir(parents=True, mode=0o755)
    write(web / "index.html", b"<p>Example</p>", 0o644)
    write(web / "assets" / "sample.js", b"export {};", 0o644)
    check("bounded admin bundle", {"WEB_DIRECTORY": web})
    write(web / "assets" / "unexpected.txt", b"Example", 0o644)
    check("unsupported web asset", {"WEB_DIRECTORY": web}, 1)
    check("explicit upstream proxy", {"UPSTREAM_HTTP_PROXY": "http://proxy.example.invalid:3128/"})
    check("credentials forbidden on proxy", {"UPSTREAM_HTTP_PROXY": "http://username@proxy.example.invalid:3128"}, 1)
    check("internationalized proxy host", {"UPSTREAM_HTTP_PROXY": "http://xn--bcher-kva.example:80"}, 1)
    check("proxy port required", {"UPSTREAM_HTTP_PROXY": "http://proxy.example.invalid"}, 1)
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="codexone-config-parity-") as directory, socket.socket() as upstream:
        upstream.bind(("127.0.0.1", 0))
        upstream.listen()
        upstream.setblocking(False)
        count = run_cases(args.reference.resolve(), args.candidate.resolve(), Path(directory), upstream)
        try:
            with upstream.accept()[0]:
                raise AssertionError("A configuration command connected to the synthetic upstream")
        except BlockingIOError:
            pass
    print(f"{count} configuration cases matched Swift exit status, stdout and stderr.")


if __name__ == "__main__":
    main()
