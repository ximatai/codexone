#!/usr/bin/env python3
"""Exercise the offline importer with synthetic catalogs only."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    with tempfile.TemporaryDirectory(prefix='codexone-profile-import-') as temporary:
        root = Path(temporary)
        source = root / 'catalog.json'
        entry = dict(slug='synthetic-text', base_instructions='Synthetic guidance', unknown=dict(nested=[True, None]))
        source.write_text(json.dumps(dict(models=[entry])))
        output = root / 'profiles.json'
        command = [sys.executable, str(Path(__file__).with_name('import_model_profiles.py')),
                   '--source', str(source), '--model', 'synthetic-text', '--source-label', 'synthetic',
                   '--revision', 'v1', '--client-version', '0.163.0', '--output', str(output)]
        def run(args, success):
            result = subprocess.run(args, capture_output=True, text=True)
            assert (result.returncode == 0) == success
            return result
        assert run(command, True).stdout == 'Imported 1 models\n'
        assert output.stat().st_mode & 0o777 == 0o600
        assert json.loads(output.read_text())['models'] == [dict(id='synthetic-text', upstream=entry)]
        before = output.read_bytes()
        run(command, False)
        assert output.read_bytes() == before
        output.unlink()
        missing = command.copy(); missing[missing.index('synthetic-text')] = 'missing'
        run(missing, False)
        run(command + ['--model', 'synthetic-text'], False)
        source.write_text(json.dumps(dict(models=[entry, entry])))
        run(command, False)
        source.write_text(json.dumps(dict(models=[entry])))
        output.symlink_to(source)
        run(command, False)
    print('PASS: offline profile conversion, missing/duplicate rejection, exclusive output and mode 0600')


if __name__ == '__main__':
    main()
