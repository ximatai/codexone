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
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('CODEXONE_', 'COMPOSE_'))}
    result = subprocess.run(command, input=data, capture_output=True, timeout=timeout, env=environment)
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
        for path in (target, target / 'secrets'):
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
        for flag in ('--uid', '--gid'):
            other = command.copy(); other[2] = str(parent / 'bad'); other[other.index(flag) + 1] = '0'
            assert run(other, ok=False).returncode != 0 and not (parent / 'bad').exists()
        malformed = parent / 'pool.json'
        for payload in ('not-json', '[]', '{"padding":"' + 'x' * 65536 + '"}'):
            malformed.write_text(payload)
            other = command.copy(); other[2] = str(parent / 'bad')
            assert run([*other, '--pool-config', str(malformed)], ok=False).returncode != 0
            assert not (parent / 'bad').exists()
        # Ambient project/service settings must not select another installation.
        original = {name: os.environ.get(name) for name in ('COMPOSE_FILE', 'CODEXONE_IMAGE')}
        try:
            os.environ['COMPOSE_FILE'] = 'synthetic-unrelated-compose.yaml'
            os.environ['CODEXONE_IMAGE'] = 'synthetic-unrelated:latest'
            output = run(['docker', 'compose', '--project-directory', str(target), 'config', '--format', 'json']).stdout
        finally:
            for name, value in original.items():
                if value is None: os.environ.pop(name, None)
                else: os.environ[name] = value
        document = json.loads(output)
        config = document['services']['gateway']
        bootstrap = document['services']['init-data']
        assert bootstrap['user'] == '0:0' and bootstrap['network_mode'] == 'none' and bootstrap['read_only']
        assert len(bootstrap['volumes']) == 1 and bootstrap['volumes'][0]['type'] == 'volume'
        assert config['depends_on']['init-data']['condition'] == 'service_completed_successfully'
        assert re.fullmatch('codexone-data-[0-9a-f]{24}', document['volumes']['data']['name'])
        assert config['image'] == IMAGE_ID
        assert config['read_only'] and config['network_mode'] == 'host' and config['restart'] == 'no'
        assert not config.get('ports') and config['user'].split(':')[0] != '0'
        assert all(secret not in output for secret in credentials)
        if binary and os.geteuid() != 0:
            (target / 'check-data').mkdir(mode=0o700)
            env = {'PATH': os.defpath, 'CODEXONE_DATA_DIRECTORY': str(target / 'check-data'),
                   'CODEXONE_ACCOUNT_POOL_CONFIG': str(target / 'secrets/pool.json'),
                   'CODEXONE_ACCOUNT_MASTER_KEY_FILE': str(target / 'secrets/master'),
                   'CODEXONE_ADMIN_TOKEN_FILE': str(target / 'secrets/admin')}
            checked = subprocess.run([str(binary.resolve()), '--check-config'], env=env, capture_output=True, timeout=10)
            assert checked.returncode == 0 and not list((target / 'check-data').iterdir())
            (target / 'secrets/admin').chmod(0o644)
            rejected = subprocess.run([str(binary.resolve()), '--check-config'], env=env, capture_output=True, timeout=10)
            assert rejected.returncode != 0
            assert all(secret not in checked.stdout + checked.stderr + rejected.stdout + rejected.stderr for secret in credentials)
    print('PASS: private exclusive initialization, ownership/modes, no overwrite/symlink/interpolation and Compose isolation'
          + ('; host binary config validation' if binary and os.geteuid() != 0 else ''))


def verify_runtime(image, browser=False):
    identifier = json.loads(run(['docker', 'image', 'inspect', image]).stdout)[0]
    assert identifier['Architecture'] == 'amd64' and identifier['Os'] == 'linux'
    assert identifier['Config']['User'] == '10001:10001'
    assert re.fullmatch('[0-9a-f]{40}', identifier['Config']['Labels']['org.opencontainers.image.revision'])
    project = 'codexone-install-' + uuid.uuid4().hex[:12]
    name = project
    with tempfile.TemporaryDirectory(prefix='codexone-oci-') as temporary:
        root = Path(temporary) / 'install'
        _, uid, gid = initialize(root, identifier['Id'])
        settings = dict(line.split('=', 1) for line in (root / '.env').read_text().splitlines())
        volume = settings['CODEXONE_DATA_VOLUME']
        assert re.fullmatch('codexone-data-[0-9a-f]{24}', volume)
        assert run(['docker', 'volume', 'inspect', volume], ok=False).returncode != 0
        admin = (root / 'secrets/admin').read_text()
        compose = ['docker', 'compose', '--project-directory', str(root), '--project-name', project]
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
        def maintenance(entrypoint, arguments, *, ok=True):
            return run([*compose, 'run', '--rm', '--no-deps', '--entrypoint', entrypoint, 'gateway', *arguments], ok=ok)
        try:
            root_target = run([*compose, 'run', '--rm', '--no-deps', '--env', 'TARGET_UID=0', 'init-data'], ok=False)
            assert root_target.returncode != 0
            run([*compose, 'run', '--rm', 'gateway', '--check-config'])
            assert not maintenance('find', ['/var/lib/codexone', '-mindepth', '1', '-maxdepth', '1', '-print']).stdout
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
            running = json.loads(run(['docker', 'inspect', name]).stdout)[0]
            host = running['HostConfig']
            assert host['ReadonlyRootfs'] and not host['Privileged'] and host['NetworkMode'] == 'host'
            assert 'ALL' in host['CapDrop'] and 'no-new-privileges:true' in host['SecurityOpt']
            assert host['Memory'] == 768 * 1024 * 1024 and host['PidsLimit'] == 128
            assert all(option in host['Tmpfs']['/tmp'] for option in ('noexec', 'nosuid'))
            mounts = {mount['Destination']: mount for mount in running['Mounts']}
            assert mounts['/var/lib/codexone']['Type'] == 'volume' and mounts['/var/lib/codexone']['RW'] and not mounts['/run/codexone']['RW']
            process = run(['docker', 'exec', name, 'cat', '/proc/1/status']).stdout.decode()
            status_fields = dict(line.split(':', 1) for line in process.splitlines() if ':' in line)
            assert status_fields['NoNewPrivs'].strip() == '1'
            assert int(status_fields['CapEff'], 16) == 0 and int(status_fields['CapBnd'], 16) == 0
            health = identifier['Config']['Healthcheck']['Test']
            assert health[0] == 'CMD-SHELL' and len(health) == 2 and '/health/live' in health[1]
            run(['docker', 'exec', name, 'sh', '-c', health[1]])
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
            licenses = run(['docker', 'exec', name, 'find', '/opt/codexone/licenses/swift', '-mindepth', '1', '-maxdepth', '1', '-type', 'd', '-printf', '%f\n']).stdout.decode().splitlines()
            pins = json.loads((REPO / 'Package.resolved').read_text())['pins']
            assert set(licenses) == {pin['identity'] for pin in pins}
            run(['docker', 'exec', name, 'test', '-s', '/opt/codexone/LICENSE'])
            npm_files = run(['docker', 'exec', name, 'find', '/opt/codexone/licenses/npm', '-type', 'f', '-size', '+0c', '-printf', '%P\n']).stdout.decode().splitlines()
            npm_lock = json.loads((REPO / 'web/package-lock.json').read_text())['packages']
            runtime_packages = {path.removeprefix('node_modules/') for path, entry in npm_lock.items()
                if path.startswith('node_modules/') and not entry.get('dev') and not entry.get('devOptional')}
            assert all(any(file.startswith(package + '/') for file in npm_files) for package in runtime_packages)
            assert run(['docker', 'exec', name, 'sh', '-c', 'command -v swift || command -v node || command -v python3'], ok=False).returncode != 0
            assert run(['docker', 'exec', name, 'touch', '/opt/codexone/forbidden'], ok=False).returncode != 0
            assert run(['docker', 'exec', name, 'touch', '/run/codexone/forbidden'], ok=False).returncode != 0
            run(['docker', 'exec', name, 'touch', '/tmp/synthetic-writable'])
            wrong_uid = 10002 if uid != 10002 else 10003
            refused_owner = run([*compose, 'run', '--rm', '--no-deps', '--env', f'TARGET_UID={wrong_uid}', 'init-data'], ok=False)
            assert refused_owner.returncode != 0 and b'Existing data volume ownership differs' in refused_owner.stderr + refused_owner.stdout
            assert run(['docker', 'exec', name, 'stat', '-c', '%u:%g', '/var/lib/codexone']).stdout.strip() == f'{uid}:{gid}'.encode()
            locked = run([*compose, 'run', '--rm', 'gateway', '--migrate'], ok=False)
            assert locked.returncode != 0
            run([*compose, 'stop'], timeout=40)
            state = json.loads(run(['docker', 'inspect', name]).stdout)[0]
            assert state['State']['ExitCode'] == 0 and not state['State']['OOMKilled'] and state['RestartCount'] == 0
            database = '/var/lib/codexone/core.sqlite'
            # v5 has the same tables; remove v6 permissions to make a legacy semantic fixture.
            fixture_sql = "BEGIN IMMEDIATE; UPDATE managed_keys SET metadata_json=json_remove(metadata_json,'$.policy.visionInput','$.policy.imageGeneration','$.policy.imageModels'); PRAGMA user_version=5; COMMIT; PRAGMA quick_check;"
            assert maintenance('sqlite3', [database, fixture_sql]).stdout.strip() == b'ok'
            before_legacy = run(['docker', 'logs', name])
            run([*compose, 'start'])
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                legacy = json.loads(run(['docker', 'inspect', name]).stdout)[0]['State']
                if not legacy['Running']: break
                time.sleep(0.2)
            assert not legacy['Running'] and legacy['ExitCode'] == 1 and not legacy['OOMKilled']
            after_legacy = run(['docker', 'logs', name])
            assert after_legacy.stdout.startswith(before_legacy.stdout) and after_legacy.stderr.startswith(before_legacy.stderr)
            rejected_logs = after_legacy.stdout[len(before_legacy.stdout):] + after_legacy.stderr[len(before_legacy.stderr):]
            assert b'LISTENING' not in rejected_logs and b'Service startup or shutdown failed.' in rejected_logs
            run([*compose, 'run', '--rm', 'gateway', '--migrate'])
            run([*compose, 'run', '--rm', 'gateway', '--migrate'])
            backups = maintenance('find', ['/var/lib/codexone', '-maxdepth', '1', '-type', 'f', '-name', 'core.sqlite.pre-v6-*.sqlite', '-printf', '%f %m %U\n']).stdout.decode().splitlines()
            assert len(backups) == 1
            backup, mode, owner = backups[0].split()
            assert re.fullmatch('core.sqlite.pre-v6-[0-9A-Fa-f-]+.sqlite', backup) and mode == '600' and owner == str(uid)
            for path, version in (('/var/lib/codexone/' + backup, 5), (database, 6)):
                rows = maintenance('sqlite3', ['-readonly', path, 'PRAGMA quick_check; PRAGMA user_version; SELECT id FROM managed_keys;']).stdout.decode().splitlines()
                assert rows == ['ok', str(version), key_id]
            run([*compose, 'start'])
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                try:
                    status, body = request('/api/keys', token=admin)
                    if status == 200: break
                except AssertionError: pass
                time.sleep(0.2)
            assert status == 200 and key_id in [key['id'] for key in json.loads(body)['keys']]
            legacy_key = next(key for key in json.loads(body)['keys'] if key['id'] == key_id)
            assert not legacy_key['visionInput'] and not legacy_key['imageGeneration'] and not legacy_key['imageModels']
            if browser:
                result = run(['node', str(REPO / 'web/scripts/install-image-ui.mjs')], timeout=90, ok=False,
                    data=json.dumps({'container': name, 'credential': admin,
                        'output': str(REPO / 'artifacts/installation-ui')}).encode())
                output = result.stdout + result.stderr
                assert all(secret.encode() not in output for secret in secrets)
                print(output.decode(), end='')
                assert result.returncode == 0, 'Packaged UI verification failed; private diagnostics withheld'
            result = run(['docker', 'logs', name])
            logs = result.stdout + result.stderr
            assert all(secret.encode() not in logs for secret in secrets)
            assert str(root).encode() not in logs
        finally:
            run([*compose, 'down', '--timeout', '30'], ok=False, timeout=40)
            # A timed-out `compose run` can outlive its CLI. Remove only this owned project.
            leftovers = run(['docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + project]).stdout.decode().splitlines()
            assert len(leftovers) <= 8 and all(re.fullmatch('[0-9a-f]{12,64}', item) for item in leftovers)
            if leftovers: run(['docker', 'rm', '--force', *leftovers])
            retained = run(['docker', 'volume', 'inspect', volume], ok=False)
            if retained.returncode == 0:
                retained_volume = json.loads(retained.stdout)[0]
                assert retained_volume['Driver'] == 'local' and retained_volume['Scope'] == 'local'
                labels = retained_volume['Labels']
                assert labels['com.docker.compose.project'] == project and labels['com.docker.compose.volume'] == 'data'
                run(['docker', 'volume', 'rm', volume])
            else:
                assert b'no such volume' in retained.stderr.lower() or b'no such object' in retained.stderr.lower()
    print('PASS: actual amd64 OCI/Compose private installation, SPA/auth/Key persistence, non-root/read-only runtime, liveness/readiness, lock, v5 backup migration/legacy denial and graceful restart')


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--binary', type=Path); parser.add_argument('--image'); parser.add_argument('--browser', action='store_true')
    args = parser.parse_args()
    if args.browser: assert args.image, '--browser requires an actual OCI image'
    verify_initializer(args.binary)
    if args.image: verify_runtime(args.image, args.browser)

if __name__ == '__main__': main()
