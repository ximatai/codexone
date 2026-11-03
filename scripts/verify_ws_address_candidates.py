#!/usr/bin/env python3
"""Real gateway WS through a dual-stack hostname and an IPv4-only loopback proxy."""
import argparse
import hashlib
import json
from pathlib import Path
import socket
import tempfile
import threading
import time

from trial_provider import Server
from verify_protocol import TOKEN, connect, start, stop
from verify_upstream_proxy import Proxy
from verify_websocket import dial, turn


def wait_empty(proxy):
    deadline = time.monotonic() + 3
    while True:
        with proxy.guard:
            remaining = len(proxy.connections)
        if remaining == 0:
            return
        assert time.monotonic() < deadline, 'proxy still owns sockets'
        time.sleep(.02)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    binary = str(parser.parse_args().binary.resolve())
    addresses = {item[4][0] for item in socket.getaddrinfo('localhost', 80, type=socket.SOCK_STREAM)}
    assert {'::1', '127.0.0.1'} <= addresses, 'requires dual-stack localhost; do not silently skip'
    provider = Server(('127.0.0.1', 0), ['synthetic-text'])
    worker = threading.Thread(target=provider.serve_forever)
    worker.start()
    proxy = Proxy(provider.server_port)
    proxy_worker = threading.Thread(target=proxy.serve_forever)
    proxy_worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-ws-candidates-') as temporary:
            for host, mode in [('127.0.0.1', 'forward'), ('localhost', 'forward'),
                               ('localhost', 'cancel'), ('localhost', 'timeout'),
                               ('localhost', 'shutdown')]:
                root = Path(temporary) / (host + '-' + mode)
                root.mkdir(mode=0o700)
                config = root / 'identity.json'
                config.write_text(json.dumps(dict(
                    principal='synthetic-principal', keyID='synthetic-key',
                    keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),
                    namespace='synthetic-candidates', identity='synthetic-upstream', reservedMicros=1,
                    upstreamTransport='websocket', models=[dict(id='synthetic-text',
                    inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
                    upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1',
                    executionTimeoutSeconds=15, firstResponseTimeoutSeconds=12,
                    progressTimeoutSeconds=12)))
                config.chmod(0o600)
                proxy.mode = 'forward' if mode == 'forward' else 'stall'
                proxy.connected.clear()
                before = proxy.requests
                process, ports = start(binary, config, root,
                    upstream_proxy=f'http://{host}:{proxy.server_address[1]}')
                try:
                    request = dict(model='synthetic-text', input='synthetic candidate test')
                    if mode == 'forward':
                        status, body = connect(ports['data'], 'POST', '/v1/responses', request)
                        assert status == 200, (host, status, proxy.requests - before)
                        with dial(ports['data']) as client:
                            assert turn(client, request)[-1]['type'] == 'response.completed'
                        assert proxy.requests == before + 2
                    elif mode == 'timeout':
                        began = time.monotonic()
                        status, _ = connect(ports['data'], 'POST', '/v1/responses', request, timeout=20)
                        assert status == 502 and 8 < time.monotonic() - began < 14
                        assert proxy.requests == before + 1
                    else:
                        with socket.create_connection(('127.0.0.1', ports['data']), timeout=3) as client:
                            body = json.dumps(request).encode()
                            client.sendall((f'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\n'
                                f'Authorization: Bearer {TOKEN}\r\nContent-Type: application/json\r\n'
                                f'Content-Length: {len(body)}\r\n\r\n').encode() + body)
                            assert proxy.connected.wait(3), 'CONNECT never reached IPv4 proxy'
                            if mode == 'shutdown':
                                process.terminate()
                                process.wait(5)
                                assert process.returncode == 0
                        # Cancel is checked while the gateway is still alive.
                    wait_empty(proxy)
                    if process.poll() is None:
                        process.terminate()
                        process.wait(5)
                    assert process.returncode == 0
                finally:
                    stop(process)
                wait_empty(proxy)
                print(f'PASS: WS proxy {host} {mode}; all observed sockets closed', flush=True)
    finally:
        proxy.close_owned()
        proxy_worker.join(5)
        provider.interrupt()
        provider.server_close()
        worker.join(5)
    assert not proxy_worker.is_alive() and not worker.is_alive() and not proxy.connections


if __name__ == '__main__':
    main()
