#!/usr/bin/env python3
"""Validate backup mounts, private installation identity, and log limits without Docker."""
import importlib.util
import os
from pathlib import Path
import runpy
import tempfile
from unittest.mock import patch

import yaml


def check():
    root = Path(__file__).resolve().parents[1]
    document = yaml.safe_load((root / 'deploy/compose.yaml').read_text())
    services = document['services']
    for service in services.values():
        assert service['logging'] == {'driver': 'json-file', 'options': {'max-size': '10m', 'max-file': '5'}}
    for name in ('init-data', 'gateway'):
        mounts = {mount['target']: mount for mount in services[name]['volumes'] if isinstance(mount, dict)}
        assert mounts['/var/backups/codexone']['source'] == 'backups'
        assert mounts['/var/backups/codexone']['volume']['nocopy'] is True
    assert services['gateway']['environment']['CODEXONE_BACKUP_DIRECTORY'] == '/var/backups/codexone'
    assert document['volumes']['backups']['name'].startswith('${CODEXONE_BACKUP_VOLUME:')
    spec = importlib.util.spec_from_file_location('initialize', root / 'deploy/init-install.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory(prefix='codexone-backup-compose-') as temporary:
        destination = Path(temporary) / 'private'
        uid, gid = (10001, 10001) if os.geteuid() == 0 else (os.geteuid(), os.getegid())
        module.initialize(destination, 'sha256:' + 'a' * 64, 'https://admin.example.invalid', root / 'deploy/pool.example.json', uid, gid)
        settings = dict(line.split('=', 1) for line in (destination / '.env').read_text().splitlines())
        assert settings['CODEXONE_BACKUP_VOLUME'] == settings['COMPOSE_PROJECT_NAME'].replace('codexone-', 'codexone-backups-', 1)
        launcher = runpy.run_path(str(destination / 'compose-install.py'))['main']
        # Exercise actual launcher selection and stripping with a synthetic exec boundary.
        for legacy in (False, True):
            if legacy:
                (destination / '.env').write_text('\n'.join(f'{k}={v}' for k, v in settings.items() if k != 'CODEXONE_BACKUP_VOLUME') + '\n')
            with patch('sys.argv', ['compose-install.py', 'config']), patch.dict(os.environ, {'CODEXONE_BACKUP_VOLUME': 'foreign-volume'}), patch('os.execvpe') as execute:
                launcher()
                assert execute.call_args.args[2]['CODEXONE_BACKUP_VOLUME'] == settings['CODEXONE_BACKUP_VOLUME']
        (destination / '.env').write_text('\n'.join(f'{k}={"foreign-volume" if k == "CODEXONE_BACKUP_VOLUME" else v}' for k, v in settings.items()) + '\n')
        with patch('sys.argv', ['compose-install.py', 'config']), patch('os.execvpe') as execute:
            assert launcher() == 1
            execute.assert_not_called()
    print('PASS: Compose YAML, backup volumes, 10m x 5 log rotation, installation identity and legacy launcher')


if __name__ == '__main__':
    check()
