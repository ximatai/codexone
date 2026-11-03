#!/usr/bin/env python3
"""Indicative macOS gateway RSS only; loopback binary/fake provider, no limit changes.

Each case starts a fresh process. ps RSS (KiB) is sampled every ~20 ms through
request encoding, dispatch, held HTTP fallback and settlement. Python client and
provider memory are excluded. This is not a Linux/container capacity acceptance.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.client
from http.server import ThreadingHTTPServer
from pathlib import Path
import platform
import subprocess
import tempfile
import threading
import time

from verify_upstream_ws_body_limit import Provider, TOKEN, call_http, configure, ledger, sized, wire
from verify_protocol import start, stop, dump_gateway_failure

MIB = 1024 * 1024


def refused_headers(port, size, status, code):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    conn.putrequest('POST', '/v1/responses')
    conn.putheader('Authorization', 'Bearer ' + TOKEN)
    conn.putheader('Content-Type', 'application/json')
    conn.putheader('Content-Length', str(size))
    conn.endheaders()
    response = conn.getresponse()
    body = response.read()
    conn.close()
    assert response.status == status and code.encode() in body, (response.status, body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    assert platform.system() == 'Darwin', 'This measurement is explicitly macOS-only'
    print(f'Platform: macOS {platform.mac_ver()[0]} {platform.machine()}; indicative only; debug binary; ps RSS sampled ~20 ms', flush=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.daemon_threads = True
    server.guard = threading.Condition()
    server.mode = 'hold'
    server.oversized_ws = 0
    server.release = threading.Event()
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-body-rss-') as temp:
            for name, size, concurrency in (('17 MiB', 17, 1), ('32 MiB', 32, 1), ('2 x 24 MiB', 24, 2)):
                root = Path(temp) / str(size)
                root.mkdir(mode=0o700)
                config = root / 'identity.json'
                configure(config, server.server_port, 'responses')
                server.calls = []
                server.release.clear()
                # Target exact ingress JSON bytes (the WS frame adds its own metadata).
                # Client/provider allocations belong to this process, excluded from gateway RSS.
                request = sized(size * MIB, 'responses')
                request['instructions'] += 'x' * (size * MIB - len(wire(request)))
                assert len(wire(request)) == size * MIB
                process, ports = start(str(args.binary.resolve()), config, root)
                samples = []
                done = threading.Event()

                def sample():
                    while not done.is_set():
                        result = subprocess.run(['ps', '-o', 'rss=', '-p', str(process.pid)],
                                                capture_output=True, text=True, check=True)
                        samples.append(int(result.stdout.strip()))
                        done.wait(.02)

                sampler = threading.Thread(target=sample)
                sampler.start()
                try:
                    time.sleep(.5)
                    idle = max(samples)
                    # Reject at headers, with no body sent and no execution admitted.
                    refused_headers(ports['data'], 32 * MIB + 1, 413, 'request_too_large')
                    with ThreadPoolExecutor(max_workers=concurrency) as pool:
                        futures = [pool.submit(call_http, ports['data'], request) for _ in range(concurrency)]
                        with server.guard:
                            assert server.guard.wait_for(lambda: len(server.calls) == concurrency, timeout=40), 'Missing held HTTP fallback'
                        assert all(path == 'http' for path, _, _ in server.calls)
                        # While both leases are owned, another 9 MiB cannot fit the 48 MiB budget.
                        if concurrency == 2:
                            refused_headers(ports['data'], 9 * MIB, 503, 'capacity_exhausted')
                        time.sleep(.5)
                        server.release.set()
                        for future in futures:
                            status, _, body = future.result(timeout=30)
                            assert status == 200, (status, body[:300])
                    rows = ledger(root, concurrency)
                    assert all(state == 'settled' for state, _, _ in rows)
                    time.sleep(.25)
                    done.set()
                    sampler.join(5)
                    peak = max(samples)
                    process.terminate()
                    process.wait(10)
                    logs = process.stdout.read()
                    assert b'path=reject_ingress' in logs and b'size_bucket=over_32_mib' in logs
                    ws_bucket = b'16_to_24_mib' if size == 17 else b'24_to_32_mib' if size == 24 else b'over_32_mib'
                    assert b'path=http' in logs and b'size_bucket=' + ws_bucket in logs
                    if concurrency == 2:
                        assert b'path=reject_budget' in logs and b'size_bucket=at_most_16_mib' in logs
                    print(f'{name}: idle_peak_rss_mib={idle / 1024:.2f}, request_peak_rss_mib={peak / 1024:.2f}, samples={len(samples)}; ingress/budget diagnostics checked', flush=True)
                except BaseException:
                    dump_gateway_failure(process)
                    raise
                finally:
                    server.release.set()
                    done.set()
                    sampler.join(5)
                    stop(process)
            assert server.oversized_ws == 0
    finally:
        server.shutdown()
        server.server_close()
        worker.join(5)


if __name__ == '__main__':
    main()
