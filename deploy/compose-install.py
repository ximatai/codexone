#!/usr/bin/env python3
"""Run Compose against this private installation, independent of ambient overrides."""
import os
from pathlib import Path
import re
import sys


def main():
    root = Path(__file__).resolve().parent
    try:
        with (root / '.env').open('rb') as manifest:
            contents = manifest.read(4097)
        if len(contents) > 4096:
            raise ValueError('Oversized installation manifest')
        settings = dict(line.split('=', 1) for line in contents.decode().splitlines())
        project = settings['COMPOSE_PROJECT_NAME']
        if not re.fullmatch(r'codexone-[0-9a-f]{24}', project):
            raise ValueError('Invalid installation identity')
        if settings['CODEXONE_DATA_VOLUME'] != 'codexone-data-' + project.removeprefix('codexone-'):
            raise ValueError('Mismatched installation volume')
        # Keep Compose's global installation selectors under this entry point's control.
        forbidden = ('-f', '--file', '-p', '--project-name', '--project-directory', '--env-file')
        arguments = sys.argv[1:]
        # Compose run/exec stop parsing flags at the service; its payload can
        # legitimately contain e.g. find's -print or another program's -p.
        selectors = arguments
        if arguments and arguments[0] in ('run', 'exec'):
            for index, argument in enumerate(arguments[1:], 1):
                if argument in ('gateway', 'init-data'):
                    selectors = arguments[:index]
                    break
        if not arguments or arguments[0].startswith('-') or any(
                arg == flag or arg.startswith(flag + '=') or
                (flag in ('-f', '-p') and arg.startswith(flag))
                for arg in selectors for flag in forbidden):
            raise ValueError('Use a Compose command without installation selectors')
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(('CODEXONE_', 'COMPOSE_'))}
        command = ['docker', 'compose', '--file', str(root / 'compose.yaml'),
                   '--env-file', str(root / '.env'), '--project-directory', str(root),
                   '--project-name', project, *arguments]
        os.execvpe(command[0], command, environment)
    except (OSError, ValueError, KeyError, UnicodeError):
        print('Installation command refused. Check the private manifest and use a Compose command without installation selectors.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
