#!/usr/bin/env python3
"""Private initialization and optional actual OCI runtime checks, without real accounts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from http.cookies import SimpleCookie
import re
import secrets as random_secrets
import subprocess
import tempfile

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
        # Static LAN initialization: no containers, interfaces or external services needed.
        assert b'--lan' in run(['python3', str(REPO / 'deploy/init-install.py'), '--help']).stdout
        lan_command = command.copy()
        index = lan_command.index('--origin')
        lan_command[index:index + 2] = ['--lan', '192.168.1.10']
        for number, (address, allowed, host) in enumerate((
                ('192.168.1.10', None, '192.168.1.10'),
                ('100.64.0.10', '100.64.0.0/24', '100.64.0.10'),
                ('fd00::10', 'fd00::/64,::1/128', '[fd00::10]'))):
            other = lan_command.copy(); other[2] = str(parent / f'lan-{number}')
            other[other.index('--lan') + 1] = address
            if allowed is not None: other += ['--lan-allow', allowed]
            result = run(other)
            settings = (Path(other[2]) / '.env').read_text()
            assert f'CODEXONE_LISTEN_ADDRESS={address}\n' in settings
            assert f'CODEXONE_ALLOWED_NETWORKS={allowed or ""}\n' in settings
            assert f'CODEXONE_ADMIN_PUBLIC_ORIGIN=http://{host}:18081\n' in settings
            assert '明文传输'.encode() in result.stdout
            assert f'http://{host}:18081'.encode() in result.stdout
            assert f'http://{host}:18080/backend-api/codex'.encode() in result.stdout
            for secret in credentials: assert secret not in result.stdout + result.stderr
            assert (Path(other[2]) / '.env').stat().st_mode & 0o777 == 0o600
        for address in ('8.8.8.8', '0.0.0.0', '::', '2001:db8::1', '127.0.0.2',
                        '169.254.1.10', 'localhost', '192.168.1.10/24', 'fd00::1%en0'):
            other = lan_command.copy(); other[2] = str(parent / 'bad')
            other[other.index('--lan') + 1] = address
            result = run(other, ok=False)
            assert result.returncode != 0 and not (parent / 'bad').exists()
            assert address.encode() not in result.stdout + result.stderr
        for suffix in (['--origin', ORIGIN], ['--lan-allow', 'bad'],
                       ['--lan-allow', '192.168.0.0/33'], ['--lan-allow', '0.0.0.0/0'],
                       ['--lan-allow', 'fd00::/129'], ['--lan-allow', '192.168.0.0/16,']):
            other = lan_command.copy(); other[2] = str(parent / 'bad')
            assert run([*other, *suffix], ok=False).returncode != 0
            assert not (parent / 'bad').exists()
        other = command.copy(); other[2] = str(parent / 'bad')
        assert run([*other, '--lan-allow', '192.168.0.0/16'], ok=False).returncode != 0
        template = (REPO / 'deploy/compose.yaml').read_text()
        for field in ('CODEXONE_LISTEN_ADDRESS', 'CODEXONE_ALLOWED_NETWORKS'):
            assert f'{field}: ${{{field}:-}}' in template
        # Ambient project/service settings must not select another installation.
        pollution = {'COMPOSE_FILE': 'synthetic-unrelated-compose.yaml',
            'COMPOSE_PROJECT_NAME': 'synthetic-unrelated-project',
            'CODEXONE_IMAGE': 'synthetic-unrelated:latest',
            'CODEXONE_DATA_VOLUME': 'synthetic-unrelated-volume',
            'CODEXONE_UID': '0', 'CODEXONE_ADMIN_PUBLIC_ORIGIN': 'http://synthetic.invalid'}
        original = {name: os.environ.get(name) for name in pollution}
        try:
            os.environ.update(pollution)
            launcher = ['python3', str(target / 'compose-install.py')]
            output = run([*launcher, 'config', '--format', 'json']).stdout
            # No containers exist: legitimate follow syntax must reach Compose.
            run([*launcher, 'logs', '-f', 'gateway'])
            for selector in ('--file=synthetic.yaml', '-fsynthetic.yaml', '--project-name', '-psynthetic'):
                assert run([*launcher, 'config', selector], ok=False).returncode != 0
        finally:
            for name, value in original.items():
                if value is None: os.environ.pop(name, None)
                else: os.environ[name] = value
        document = json.loads(output)
        config = document['services']['gateway']
        bootstrap = document['services']['init-data']
        assert bootstrap['user'] == '0:0' and bootstrap['network_mode'] == 'none' and bootstrap['read_only']
        assert len(bootstrap['volumes']) == 2 and bootstrap['volumes'][0]['type'] == 'volume'
        assert bootstrap['volumes'][0]['volume']['nocopy']
        assert next(mount for mount in config['volumes'] if mount['target'] == '/var/lib/codexone')['volume']['nocopy']
        assert config['environment']['CODEXONE_BACKUP_DIRECTORY'] == '/var/backups/codexone'
        assert next(mount for mount in config['volumes'] if mount['target'] == '/var/backups/codexone')['source'] == 'backups'
        assert all(service['logging'] == {'driver': 'json-file', 'options': {'max-size': '10m', 'max-file': '5'}} for service in document['services'].values())
        assert document['volumes']['backups']['name'] == document['name'].replace('codexone-', 'codexone-backups-', 1)
        assert config['depends_on']['init-data']['condition'] == 'service_completed_successfully'
        assert re.fullmatch('codexone-data-[0-9a-f]{24}', document['volumes']['data']['name'])
        assert re.fullmatch('codexone-[0-9a-f]{24}', document['name'])
        assert document['volumes']['data']['name'] == document['name'].replace('codexone-', 'codexone-data-', 1)
        assert config['environment']['CODEXONE_ADMIN_PUBLIC_ORIGIN'] == ORIGIN
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
    print('PASS: static LAN flags, origin exclusion, private env/risk/URLs, public/CIDR rejection; private exclusive initialization, ownership/modes, no overwrite/symlink/interpolation and Compose isolation'
          + ('; host binary config validation' if binary and os.geteuid() != 0 else ''))


def verify_runtime(image, browser=False, previous_image=None, incompatible_image=None, browser_output=None, incompatible_schema=6):
    identifier = json.loads(run(['docker', 'image', 'inspect', image]).stdout)[0]
    assert identifier['Architecture'] == 'amd64' and identifier['Os'] == 'linux'
    assert identifier['Config']['User'] == '10001:10001'
    assert re.fullmatch('[0-9a-f]{40}', identifier['Config']['Labels']['org.opencontainers.image.revision'])
    with tempfile.TemporaryDirectory(prefix='codexone-oci-') as temporary:
        root = Path(temporary) / 'install'
        _, uid, gid = initialize(root, identifier['Id'])
        settings = dict(line.split('=', 1) for line in (root / '.env').read_text().splitlines())
        project = settings['COMPOSE_PROJECT_NAME']
        name = project
        volume = settings['CODEXONE_DATA_VOLUME']
        assert re.fullmatch('codexone-data-[0-9a-f]{24}', volume)
        assert run(['docker', 'volume', 'inspect', volume], ok=False).returncode != 0
        admin = (root / 'secrets/admin').read_text()
        compose = ['python3', str(root / 'compose-install.py')]
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
            status, login, raw_headers = request('/api/session', body={'username': 'admin', 'secret': admin}, headers=['Origin: ' + ORIGIN, 'Host: admin.example.invalid'], response_headers=True)
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
            assert manifest['schemaVersion'] == 10
            storage_status, storage_body = request('/api/runtime/storage', token=admin)
            assert storage_status == 200 and json.loads(storage_body)['reserveTargetBytes'] == 64 * 1024 * 1024
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
            fault = root / 'fault'; fault.mkdir(mode=0o700)
            (fault / 'find').write_text("#!/bin/sh\necho 'Synthetic data listing failure' >&2\nexit 1\n")
            (fault / 'find').chmod(0o755)
            failed_listing = run([*compose, 'run', '--rm', '--no-deps', '--env', f'TARGET_UID={wrong_uid}',
                '--env', 'PATH=/probe:/usr/bin:/bin', '--volume', f'{fault}:/probe:ro', 'init-data'], ok=False)
            assert failed_listing.returncode != 0 and b'Synthetic data listing failure' in failed_listing.stdout + failed_listing.stderr
            assert run(['docker', 'exec', name, 'stat', '-c', '%u:%g', '/var/lib/codexone']).stdout.strip() == f'{uid}:{gid}'.encode()
            refused_owner = run([*compose, 'run', '--rm', '--no-deps', '--env', f'TARGET_UID={wrong_uid}', 'init-data'], ok=False)
            assert refused_owner.returncode != 0 and b'Existing volume ownership differs' in refused_owner.stderr + refused_owner.stdout
            assert run(['docker', 'exec', name, 'stat', '-c', '%u:%g', '/var/lib/codexone']).stdout.strip() == f'{uid}:{gid}'.encode()
            locked = run([*compose, 'run', '--rm', 'gateway', '--migrate'], ok=False)
            assert locked.returncode != 0
            run([*compose, 'stop'], timeout=40)
            state = json.loads(run(['docker', 'inspect', name]).stdout)[0]
            assert state['State']['ExitCode'] == 0 and not state['State']['OOMKilled'] and state['RestartCount'] == 0
            run([*compose, 'run', '--rm', 'gateway', '--key-status'])
            run([*compose, 'run', '--rm', 'gateway', '--backup', '/var/lib/codexone/installation-bundle'])
            run([*compose, 'run', '--rm', 'gateway', '--verify-backup', '/var/lib/codexone/installation-bundle'])
            database = '/var/lib/codexone/core.sqlite'
            if previous_image or incompatible_image:
                # Preserve the same local volume and secrets; never use schema edits for rollback.
                manifest_path = root / '.env'
                original_manifest = manifest_path.read_text()
                def select_image(reference):
                    inspected = json.loads(run(['docker', 'image', 'inspect', reference]).stdout)[0]
                    assert inspected['Architecture'] == 'amd64' and inspected['Os'] == 'linux'
                    manifest_path.write_text(re.sub(r'^CODEXONE_IMAGE=.*$', 'CODEXONE_IMAGE=' + inspected['Id'], original_manifest, flags=re.MULTILINE))
                    return inspected['Id']
                def truth():
                    return maintenance('sqlite3', ['-readonly', database,
                        "PRAGMA user_version; SELECT id||':'||digest||':'||metadata_json FROM managed_keys ORDER BY id; SELECT id||':'||state||':'||reserved||':'||estimated FROM attempts ORDER BY id;"]).stdout
                # Structural rollback sentinel, not an imported protocol execution.
                # Real settled/unknown execution is covered by verify_migration_cutback.py.
                maintenance('sqlite3', [database,
                    "INSERT INTO attempts(id,principal,key_id,namespace,identity,window_id,policy_version,pricing_version,reserved,state,admission_json) VALUES('synthetic-rollback-obligation','synthetic','synthetic','synthetic','synthetic','synthetic','1','1',17,'unknown','{}');"])
                original_master = (root / 'secrets/master').read_text()
                active_master = random_secrets.token_hex(32)
                keyring = json.dumps({'format': 1, 'active': active_master, 'decryptOnly': [original_master]})
                (root / 'secrets/master').write_text(keyring)
                secrets.extend([active_master, keyring])
                current_keys = json.loads(run([*compose, 'run', '--rm', 'gateway', '--key-status']).stdout)
                before_switch = truth()
                current_binary = maintenance('sha256sum', ['/usr/local/bin/codexone']).stdout.split()[0]
                if incompatible_image:
                    # Prove schema rejection, not rejection of the newer keyring format.
                    (root / 'secrets/master').write_text(original_master)
                    select_image(incompatible_image)
                    run([*compose, 'run', '--rm', 'gateway', '--check-config'])
                    # The old binary has a generic safe startup error. Positively control
                    # its complete startup under the same config/UID/volume/secret mounts.
                    control = run([*compose, 'run', '--rm', '--no-deps', '-d',
                                   '--env', 'CODEXONE_DATA_DIRECTORY=/var/lib/codexone/schema-control',
                                   'gateway']).stdout.decode().strip()
                    assert re.fullmatch('[0-9a-f]{12,64}', control)
                    saved_name = name
                    try:
                        name = control
                        deadline = time.monotonic() + 25
                        while time.monotonic() < deadline:
                            try:
                                if request('/health/live')[0] == 200: break
                            except AssertionError: pass
                            time.sleep(0.2)
                        else: raise AssertionError('Old schema rejection lacks a successful startup control')
                        assert maintenance('sqlite3', ['-readonly', '/var/lib/codexone/schema-control/core.sqlite', 'PRAGMA user_version;']).stdout.strip() == str(incompatible_schema).encode()
                        assert maintenance('stat', ['-c', '%a:%u:%g', '/var/lib/codexone/schema-control/core.sqlite']).stdout == maintenance('stat', ['-c', '%a:%u:%g', database]).stdout
                    finally:
                        run(['docker', 'stop', '--time', '10', control], ok=False, timeout=20)
                        run(['docker', 'rm', '--force', control], ok=False)
                        name = saved_name
                    rejected = run([*compose, 'run', '--rm', 'gateway'], ok=False, timeout=20)
                    assert rejected.returncode != 0 and b'LISTENING' not in rejected.stdout + rejected.stderr
                    assert truth() == before_switch
                    (root / 'secrets/master').write_text(keyring)
                if previous_image:
                    previous_id = select_image(previous_image)
                    assert previous_id != identifier['Id'], 'Rollback requires a distinct actual image'
                    assert maintenance('sha256sum', ['/usr/local/bin/codexone']).stdout.split()[0] != current_binary, 'Rollback requires a distinct binary'
                    rollback_keys = json.loads(run([*compose, 'run', '--rm', 'gateway', '--key-status']).stdout)
                    assert rollback_keys['activeKeyID'] == current_keys['activeKeyID']
                    assert rollback_keys['availableKeyIDs'] == current_keys['availableKeyIDs']
                    run([*compose, 'up', '-d'])
                    name = run([*compose, 'ps', '-q', 'gateway']).stdout.decode().strip()
                    deadline = time.monotonic() + 25
                    while time.monotonic() < deadline:
                        try:
                            if request('/api/keys', token=admin)[0] == 200: break
                        except AssertionError: pass
                        time.sleep(0.2)
                    else: raise AssertionError('Compatible rollback did not become manageable')
                    assert truth() == before_switch
                    run([*compose, 'stop'], timeout=40)
                manifest_path.write_text(original_manifest)
                run([*compose, 'up', '-d'])
                name = run([*compose, 'ps', '-q', 'gateway']).stdout.decode().strip()
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    try:
                        if request('/api/runtime/storage', token=admin)[0] == 200: break
                    except AssertionError: pass
                    time.sleep(0.2)
                else: raise AssertionError('Upgrade did not restore current v10 observation')
                assert truth() == before_switch
                run([*compose, 'stop'], timeout=40)
                checks = []
                if previous_image: checks.append('distinct compatible v10 rollback/re-upgrade')
                if incompatible_image: checks.append(f'old v{incompatible_schema} positive startup control and v10 rejection')
                print('PASS: ' + '; '.join(checks) + '; same-volume Key and unknown obligation retained')
            # v5 has the same tables; remove v6 permissions to make a legacy semantic fixture.
            fixture_sql = "BEGIN IMMEDIATE; DROP INDEX attempts_active_identity; DROP INDEX attempts_retention; DROP INDEX attempts_unknown_since; ALTER TABLE attempts DROP COLUMN unknown_since_epoch; ALTER TABLE attempts DROP COLUMN closed_unknown_at_epoch; DROP INDEX bindings_expiry; ALTER TABLE bindings DROP COLUMN expires_at_epoch; DROP TABLE usage_daily; DROP TABLE account_concurrency; ALTER TABLE accounts DROP COLUMN display_name; DROP INDEX attempts_in_flight; UPDATE managed_keys SET metadata_json=json_remove(metadata_json,'$.policy.visionInput','$.policy.imageGeneration','$.policy.imageModels'); DROP TABLE maintenance_events; DROP TABLE maintenance_state; PRAGMA user_version=5; COMMIT; PRAGMA quick_check;"
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
            backups = maintenance('find', ['/var/lib/codexone', '-maxdepth', '1', '-type', 'f', '-name', 'core.sqlite.pre-v10-*.sqlite', '-printf', '%f %m %U\n']).stdout.decode().splitlines()
            assert len(backups) == 1
            backup, mode, owner = backups[0].split()
            assert re.fullmatch('core.sqlite.pre-v10-[0-9A-Fa-f-]+.sqlite', backup) and mode == '600' and owner == str(uid)
            for path, version in (('/var/lib/codexone/' + backup, 5), (database, 10)):
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
                        'output': str(browser_output or REPO / 'artifacts/installation-ui')}).encode())
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
            for volume_name, volume_kind in ((volume, 'data'), (settings['CODEXONE_BACKUP_VOLUME'], 'backups')):
                retained = run(['docker', 'volume', 'inspect', volume_name], ok=False)
                if retained.returncode == 0:
                    retained_volume = json.loads(retained.stdout)[0]
                    assert retained_volume['Driver'] == 'local' and retained_volume['Scope'] == 'local'
                    labels = retained_volume['Labels']
                    assert labels['com.docker.compose.project'] == project and labels['com.docker.compose.volume'] == volume_kind
                    run(['docker', 'volume', 'rm', volume_name])
                else:
                    assert b'no such volume' in retained.stderr.lower() or b'no such object' in retained.stderr.lower()
    print('PASS: actual amd64 OCI/Compose private installation, SPA/auth/Key persistence, non-root/read-only runtime, liveness/readiness, lock, v5 backup migration/legacy denial and graceful restart')


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--binary', type=Path); parser.add_argument('--image'); parser.add_argument('--browser', action='store_true'); parser.add_argument('--previous-image'); parser.add_argument('--incompatible-image'); parser.add_argument('--incompatible-schema', type=int, choices=[6, 7, 8, 9], default=6); parser.add_argument('--browser-output', type=Path)
    args = parser.parse_args()
    if args.browser: assert args.image, '--browser requires an actual OCI image'
    if args.browser_output: assert args.browser, '--browser-output requires --browser'
    verify_initializer(args.binary)
    if args.previous_image or args.incompatible_image: assert args.image
    if args.image: verify_runtime(args.image, args.browser, args.previous_image, args.incompatible_image, args.browser_output, args.incompatible_schema)

if __name__ == '__main__': main()
