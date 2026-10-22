#!/usr/bin/env python3
"""Private initialization and optional actual OCI runtime checks, without real accounts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from http.cookies import SimpleCookie
import re
import subprocess
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[1]
IMAGE_ID = 'sha256:' + 'a' * 64
ORIGIN = 'https://admin.example.invalid'


def run(command, *, data=None, ok=True, timeout=30):
    result = subprocess.run(command, input=data, capture_output=True, timeout=timeout)
    if ok:
        assert result.returncode == 0, 'Synthetic installation command failed; private diagnostics withheld'
    return result


def initialize(root, image=IMAGE_ID):
    uid = os.geteuid() or 10001
    gid = os.getegid() if os.geteuid() else 10001
    command = ['python3', str(REPO / 'deploy/init-install.py'), str(root), '--image', image,
               '--origin', ORIGIN, '--uid', str(uid), '--gid', str(gid)]
    run(command)
    return command, uid, gid


def verify_initializer(binary):
    with tempfile.TemporaryDirectory(prefix='codexone-install-') as temporary:
        parent = Path(temporary)
        target = parent / 'install'
        command, uid, _ = initialize(target)
        credentials = [(target / 'secrets' / name).read_bytes() for name in ('admin', 'master')]
        assert len(credentials[0]) >= 32 and re.fullmatch(rb'[0-9a-f]{64}', credentials[1])
        for path in (target, target / 'data', target / 'secrets'):
            assert path.stat().st_mode & 0o777 == 0o700 and path.stat().st_uid == uid
        for path in target.rglob('*'):
            if path.is_file():
                assert path.stat().st_mode & 0o777 == 0o600
        before = {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).digest()
                  for p in target.rglob('*') if p.is_file()}
        refused = run(command, ok=False)
        assert refused.returncode != 0
        after = {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).digest()
                 for p in target.rglob('*') if p.is_file()}
        assert before == after
        link = parent / 'link'; link.symlink_to(target, target_is_directory=True)
        other = command.copy(); other[2] = str(link)
        assert run(other, ok=False).returncode != 0
        for bad in ('https://${HOME}', 'https://admin.example.invalid/path', 'http://admin.example.invalid'):
            other = command.copy(); other[2] = str(parent / 'bad'); other[other.index('--origin') + 1] = bad
            assert run(other, ok=False).returncode != 0 and not (parent / 'bad').exists()
        for bad in ('codexone:latest', 'sha256:short', 'registry.example/${SECRET}@sha256:' + 'b' * 64):
            other = command.copy(); other[2] = str(parent / 'bad'); other[other.index('--image') + 1] = bad
            assert run(other, ok=False).returncode != 0 and not (parent / 'bad').exists()
        malformed = parent / 'pool.json'
        for payload in ('not-json', '[]', '{"padding":"' + 'x' * 65536 + '"}'):
            malformed.write_text(payload)
            other = command.copy(); other[2] = str(parent / 'bad')
            assert run([*other, '--pool-config', str(malformed)], ok=False).returncode != 0
            assert not (parent / 'bad').exists()
        output = run(['docker', 'compose', '--project-directory', str(target), 'config', '--format', 'json']).stdout
        config = json.loads(output)['services']['gateway']
        assert config['read_only'] and config['network_mode'] == 'host' and config['restart'] == 'no'
        assert not config.get('ports') and config['user'].split(':')[0] != '0'
        assert all(secret not in output for secret in credentials)
        if binary and os.geteuid() != 0:
            env = {'PATH': os.defpath, 'CODEXONE_DATA_DIRECTORY': str(target / 'data'),
                   'CODEXONE_ACCOUNT_POOL_CONFIG': str(target / 'secrets/pool.json'),
                   'CODEXONE_ACCOUNT_MASTER_KEY_FILE': str(target / 'secrets/master'),
                   'CODEXONE_ADMIN_TOKEN_FILE': str(target / 'secrets/admin')}
            checked = subprocess.run([str(binary.resolve()), '--check-config'], env=env, capture_output=True, timeout=10)
            assert checked.returncode == 0 and not list((target / 'data').iterdir())
            (target / 'secrets/admin').chmod(0o644)
            rejected = subprocess.run([str(binary.resolve()), '--check-config'], env=env, capture_output=True, timeout=10)
            assert rejected.returncode != 0
            assert all(secret not in checked.stdout + checked.stderr + rejected.stdout + rejected.stderr for secret in credentials)
    print('PASS: private exclusive initialization, ownership/modes, no overwrite/symlink/interpolation, Compose isolation and binary config validation')


def verify_runtime(image):
    identifier = json.loads(run(['docker', 'image', 'inspect', image]).stdout)[0]
    assert identifier['Architecture'] == 'amd64' and identifier['Os'] == 'linux'
    assert identifier['Config']['User'] == '10001:10001'
    assert re.fullmatch('[0-9a-f]{40}', identifier['Config']['Labels']['org.opencontainers.image.revision'])
    name = 'codexone-install-' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix='codexone-oci-') as temporary:
        root = Path(temporary) / 'install'
        _, uid, _ = initialize(root, identifier['Id'])
        # TemporaryDirectory itself is private; only the bind mounts are visible to the runtime UID.
        admin = (root / 'secrets/admin').read_text()
        compose = ['docker', 'compose', '--project-directory', str(root), '--project-name', name]
        secrets = [admin, (root / 'secrets/master').read_text()]
        def request(path, *, body=None, token=None, headers=None, response_headers=False):
            settings = ['url = ' + json.dumps('http://127.0.0.1:18081' + path)]
            for header in (headers or []) + (['Authorization: Bearer ' + token] if token else []):
                settings.append('header = ' + json.dumps(header))
            if body is not None:
                settings += ['request = "POST"', 'header = "Content-Type: application/json"', 'data = ' + json.dumps(json.dumps(body))]
            raw = run(['docker', 'exec', '-i', name, 'curl', *(['--dump-header', '-'] if response_headers else []), '--silent', '--show-error', '--max-time', '5',
                       '--write-out', '\n%{http_code}', '--config', '-'], data=('\n'.join(settings) + '\n').encode()).stdout
            payload, status = raw.rsplit(b'\n', 1)
            if response_headers:
                raw_headers, payload = payload.split(b'\r\n\r\n', 1)
                return int(status), payload, raw_headers.decode()
            return int(status), payload
        try:
            run([*compose, 'run', '--rm', 'gateway', '--check-config'])
            assert not list((root / 'data').iterdir())
            (root / 'secrets/admin').chmod(0o644)
            rejected = run([*compose, 'run', '--rm', 'gateway', '--check-config'], ok=False)
            assert rejected.returncode != 0
            assert all(secret.encode() not in rejected.stdout + rejected.stderr for secret in secrets)
            (root / 'secrets/admin').chmod(0o600)
            run([*compose, 'up', '-d'])
            name = run([*compose, 'ps', '-q', 'gateway']).stdout.decode().strip()
            assert re.fullmatch('[0-9a-f]{12,64}', name)
            import time
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                try:
                    if request('/health/live')[0] == 200: break
                except AssertionError: pass
                time.sleep(0.2)
            else: raise AssertionError('OCI candidate did not become live')
            assert request('/health/ready')[0] == 503
            status, html = request('/'); assert status == 200
            asset = re.search(rb'/assets/[^" ]+\.js', html); assert asset
            assert request(asset[0].decode())[0] == 200
            assert request('/api/keys')[0] == 401
            status, login, raw_headers = request('/api/session', body={'secret': admin}, headers=['Origin: ' + ORIGIN, 'Host: admin.example.invalid'], response_headers=True)
            assert status == 200 and 'csrf' in json.loads(login)
            cookies = SimpleCookie()
            for line in raw_headers.splitlines():
                if line.lower().startswith('set-cookie:'): cookies.load(line.split(':', 1)[1].strip())
            session = cookies['__Host-codexone_admin']
            assert session['secure'] and session['httponly'] and session['samesite'] == 'Strict'
            csrf = json.loads(login)['csrf']; secrets.extend([session.value, csrf])
            browser_headers = ['Cookie: __Host-codexone_admin=' + session.value, 'Host: admin.example.invalid', 'Origin: ' + ORIGIN]
            create = {'principal': 'synthetic-install', 'models': ['configure-model-before-use'],
                'limits': {'requests': 10, 'active': 2, 'unresolved': 2, 'budgetMicros': 1000000, 'unresolvedMicros': 1000000}}
            assert request('/api/keys', headers=browser_headers, body=create)[0] == 403
            assert request('/api/keys', headers=[*browser_headers, 'X-CodexOne-CSRF: wrong'], body=create)[0] == 403
            status, body = request('/api/keys', headers=[*browser_headers, 'X-CodexOne-CSRF: ' + csrf], body=create)
            assert status == 201
            created = json.loads(body); secrets.append(created['secret'])
            key_id = created['key']['id']
            assert request('/api/keys', token=created['secret'])[0] == 401
            assert run(['docker', 'exec', name, 'id', '-u']).stdout.strip() == str(uid).encode()
            manifest = json.loads(run(['docker', 'exec', name, 'cat', '/opt/release.json']).stdout)
            assert manifest['revision'] == identifier['Config']['Labels']['org.opencontainers.image.revision']
            assert run(['docker', 'exec', name, 'sh', '-c', 'command -v swift || command -v node'], ok=False).returncode != 0
            assert run(['docker', 'exec', name, 'touch', '/opt/codexone/forbidden'], ok=False).returncode != 0
            run(['docker', 'exec', name, 'touch', '/tmp/synthetic-writable'])
            locked = run([*compose, 'run', '--rm', 'gateway', '--migrate'], ok=False)
            assert locked.returncode != 0
            run([*compose, 'stop'], timeout=40)
            state = json.loads(run(['docker', 'inspect', name]).stdout)[0]
            assert state['State']['ExitCode'] == 0 and not state['State']['OOMKilled'] and state['RestartCount'] == 0
            run([*compose, 'run', '--rm', 'gateway', '--migrate'])
            run([*compose, 'start'])
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                try:
                    status, body = request('/api/keys', token=admin)
                    if status == 200: break
                except AssertionError: pass
                time.sleep(0.2)
            assert status == 200 and key_id in [key['id'] for key in json.loads(body)['keys']]
            result = run(['docker', 'logs', name])
            logs = result.stdout + result.stderr
            assert all(secret.encode() not in logs for secret in secrets)
            assert str(root).encode() not in logs
        finally:
            run([*compose, 'down', '--timeout', '30'], ok=False, timeout=40)
    print('PASS: actual amd64 OCI/Compose private installation, SPA/auth/Key persistence, non-root/read-only runtime, liveness/readiness, lock, migration and graceful restart')


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--binary', type=Path); parser.add_argument('--image')
    args = parser.parse_args()
    verify_initializer(args.binary)
    if args.image: verify_runtime(args.image)

if __name__ == '__main__': main()
