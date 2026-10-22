#!/usr/bin/env python3
"""Real socket regression for bounded management assets: slow readers and peer disconnects."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
from pathlib import Path
import platform
import socket
import tempfile
import time

from verify_admin import running_admin


def verify(binary):
    with tempfile.TemporaryDirectory(prefix='codexone-assets-') as temporary:
        root = Path(temporary)
        (root/'assets').mkdir(mode=0o700)
        (root/'index.html').write_text('<!doctype html><title>Synthetic assets</title>')
        payload = b'/*' + b's' * (1048576-4) + b'*/'
        (root/'assets'/'large.js').write_bytes(payload)
        digest = hashlib.sha256(payload).digest()
        with running_admin(binary, root) as fixture:
            port = fixture.ports['admin']
            def connection():
                client = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
                client.connect()
                client.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
                client.request('GET', '/assets/large.js', headers={'Accept-Encoding': 'gzip, deflate, br, zstd'})
                response = client.getresponse()
                assert response.status == 200 and response.getheader('Content-Length') == str(len(payload))
                assert response.getheader('Connection') == 'close'
                assert response.getheader('Content-Security-Policy') is not None
                return client, response
            def read(_):
                client, response = connection()
                try:
                    received = hashlib.sha256(); count = 0
                    while chunk := response.read(8192):
                        count += len(chunk); received.update(chunk)
                        time.sleep(0.001)
                    assert count == len(payload) and received.digest() == digest, 'Management asset truncated'
                finally: client.close()
            # The resource is at the existing 1MiB per-asset limit, below the 4MiB bundle limit.
            with ThreadPoolExecutor(max_workers=4) as executor:
                list(executor.map(read, range(8)))
            for _ in range(8):
                client, _ = connection(); client.close()
            read(0)
            client = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            try:
                client.request('GET', '/health/live'); response = client.getresponse()
                assert response.status == 200; response.read()
            finally: client.close()
    print('PASS: '+platform.system()+' '+platform.machine()+' management 1MiB assets, concurrent slow readers, exact bytes, peer disconnect and continued service')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    verify(str(args.binary.resolve()))
