#!/usr/bin/env python3
"""Create a new private Linux installation; never replace an existing installation."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import sys
from urllib.parse import urlsplit


PRIVATE_NETWORKS = tuple(ipaddress.ip_network(cidr) for cidr in (
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10', 'fc00::/7'))
DEFAULT_NETWORKS = PRIVATE_NETWORKS + (ipaddress.ip_network('127.0.0.0/8'), ipaddress.ip_network('::1/128'))
RISK = ('局域网 HTTP 模式：管理员秘密、session、Key 与请求内容在局域网中明文传输。'
        '同一网络的设备可截获这些信息。不要在公共或不可信 Wi-Fi 使用，不要用端口转发暴露到公网；'
        '跨网络访问请使用 HTTPS 或 Tailscale 等私有网络。')


def lan_settings(address, allow):
    ip = ipaddress.ip_address(address)
    if '%' in address or not any(ip in network for network in PRIVATE_NETWORKS):
        raise ValueError('Use a private literal LAN address.')
    if allow is not None:
        parts = allow.split(',')
        if not allow or len(parts) > 64:
            raise ValueError('Use a bounded list of source CIDRs.')
        for part in parts:
            if not re.fullmatch(r'[0-9A-Fa-f:.]+/[0-9]+', part):
                raise ValueError('Use literal source CIDRs.')
            network = ipaddress.ip_network(part, strict=False)
            if not any(network.version == parent.version and network.subnet_of(parent) for parent in DEFAULT_NETWORKS):
                raise ValueError('Source CIDRs must narrow private or loopback networks.')
    host = f'[{ip}]' if ip.version == 6 else str(ip)
    return str(ip), f'http://{host}:18081', f'http://{host}:18080/backend-api/codex'


def initialize(destination, image, origin, pool, uid, gid, lan=None, lan_allow=None):
    if not re.fullmatch(r'(?:[A-Za-z0-9][A-Za-z0-9._:/-]*@)?sha256:[0-9a-f]{64}', image):
        raise ValueError('Use a digest reference or a local sha256 image ID.')
    if lan is not None:
        if origin is not None:
            raise ValueError('LAN and explicit origin are mutually exclusive.')
        lan, origin, _ = lan_settings(lan, lan_allow)
    elif lan_allow is not None:
        raise ValueError('Source CIDRs require LAN mode.')
    url = urlsplit(origin)
    if (url.scheme != ('http' if lan is not None else 'https') or not url.hostname or url.username or url.password or url.path not in ('', '/')
            or url.query or url.fragment or any(c.isspace() for c in origin)):
        raise ValueError('Use an exact HTTPS management origin.')
    if not re.fullmatch(r'[A-Za-z0-9.-]+|[0-9A-Fa-f:]+', url.hostname):
        raise ValueError('Use a literal ASCII management host without interpolation.')
    # Also rejects malformed and out-of-range ports without echoing the origin.
    _ = url.port
    if uid <= 0 or gid <= 0 or uid > 2147483647 or gid > 2147483647:
        raise ValueError('Choose non-root runtime UID and GID values.')
    if os.geteuid() != 0 and (uid != os.geteuid() or gid not in (os.getegid(), *os.getgroups())):
        raise ValueError('Runtime ownership must match this user, or initialize as root with explicit non-root UID/GID.')
    source = Path(pool)
    with source.open('rb') as file:
        contents = file.read(65537)
    if len(contents) > 65536 or not isinstance(json.loads(contents), dict):
        raise ValueError('Pool configuration must be a bounded JSON object.')
    previous_mask = os.umask(0o077)
    try:
        # Exclusive creation is the barrier: existing directories/symlinks always fail.
        destination.mkdir(mode=0o700)
        (destination / 'secrets').mkdir(mode=0o700)
        installation = secrets.token_hex(12)
        values = {
            'secrets/admin': secrets.token_urlsafe(48).encode(),
            'secrets/master': secrets.token_hex(32).encode(),
            'secrets/pool.json': contents,
            '.env': (f'COMPOSE_PROJECT_NAME=codexone-{installation}\nCODEXONE_DATA_VOLUME=codexone-data-{installation}\n'
                     f'CODEXONE_BACKUP_VOLUME=codexone-backups-{installation}\n'
                     f'CODEXONE_IMAGE={image}\nCODEXONE_UID={uid}\nCODEXONE_GID={gid}\n'
                     f'CODEXONE_ADMIN_PUBLIC_ORIGIN={origin.rstrip("/")}\n'
                     + (f'CODEXONE_LISTEN_ADDRESS={lan}\n'
                        f'CODEXONE_ALLOWED_NETWORKS={lan_allow or ""}\n' if lan is not None else '')).encode(),
            'compose.yaml': Path(__file__).with_name('compose.yaml').read_bytes(),
            'compose-install.py': Path(__file__).with_name('compose-install.py').read_bytes(),
        }
        for name, value in values.items():
            descriptor = os.open(destination / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, 'wb') as output:
                output.write(value)
                output.flush()
                os.fsync(output.fileno())
        for path in sorted(destination.rglob('*'), reverse=True):
            if path.is_symlink():
                raise ValueError('Unexpected installation symlink.')
            os.chown(path, uid, gid)
        os.chown(destination, uid, gid)
        for directory in (destination / 'secrets', destination, destination.parent.resolve()):
            descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    finally:
        os.umask(previous_mask)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--image', required=True)
    route = parser.add_mutually_exclusive_group(required=True)
    route.add_argument('--origin', help='Exact HTTPS management origin')
    route.add_argument('--lan', metavar='ADDRESS', help='Private literal LAN address; accepts plaintext risk')
    parser.add_argument('--lan-allow', metavar='CIDR,...', help='Narrow allowed source networks (requires --lan)')
    parser.add_argument('--pool-config', type=Path, default=Path(__file__).with_name('pool.example.json'))
    parser.add_argument('--uid', type=int, default=os.geteuid())
    parser.add_argument('--gid', type=int, default=os.getegid())
    args = parser.parse_args()
    try:
        initialize(args.directory.absolute(), args.image, args.origin, args.pool_config, args.uid, args.gid, args.lan, args.lan_allow)
    except (OSError, ValueError, json.JSONDecodeError):
        print('Initialization refused or incomplete. Existing content was not replaced; inspect the private directory before retrying with a new path.', file=sys.stderr)
        return 1
    if args.lan:
        _, origin, base_url = lan_settings(args.lan, args.lan_allow)
        print(RISK)
        print(f'管理地址: {origin}')
        print(f'客户端 base_url: {base_url}')
    print('Private installation initialized. Review pool model settings before starting Compose. Credentials remain in private files.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
