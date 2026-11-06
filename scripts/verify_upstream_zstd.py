#!/usr/bin/env python3
"""Synthetic socket matrix and optional RSS gate for the actual gateway binary."""
import argparse
import base64
import ctypes as C
import ctypes.util
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import random
import socket
import sqlite3
import struct
import subprocess
import tempfile
import threading
import time

from verify_protocol import TOKEN, start, stop, dump_gateway_failure
from verify_json_order import wire, EVENT, REQUEST

MIB = 1024 * 1024


class Buffer(C.Structure):
    _fields_ = [('data', C.c_void_p), ('size', C.c_size_t), ('pos', C.c_size_t)]


class Decoder:
    """Bounded streaming verifier; rejects trailing frames, truncation and invalid tails."""
    def __init__(self):
        name = ctypes.util.find_library('zstd')
        if not name and os.uname().sysname == 'Darwin':
            # A local test prerequisite, never a product runtime dependency.
            name = '/opt/homebrew/lib/libzstd.dylib'
        self.lib = C.CDLL(name or 'libzstd.so.1')
        self.lib.ZSTD_createDStream.restype = C.c_void_p
        self.lib.ZSTD_freeDStream.argtypes = [C.c_void_p]
        self.lib.ZSTD_initDStream.argtypes = [C.c_void_p]
        self.lib.ZSTD_initDStream.restype = C.c_size_t
        self.lib.ZSTD_decompressStream.argtypes = [C.c_void_p, C.POINTER(Buffer), C.POINTER(Buffer)]
        self.lib.ZSTD_decompressStream.restype = C.c_size_t
        self.lib.ZSTD_isError.argtypes = [C.c_size_t]
        self.lib.ZSTD_isError.restype = C.c_uint
        self.context = self.lib.ZSTD_createDStream()
        assert self.context
        assert not self.lib.ZSTD_isError(self.lib.ZSTD_initDStream(self.context))
        self.output = C.create_string_buffer(65536)
        self.done = False
        self.prefix = b''

    def feed(self, part, consume):
        assert not self.done, 'Extra frame or tail'
        if len(self.prefix) < 5:
            self.prefix = (self.prefix + part)[:5]
            if len(self.prefix) == 5:
                assert self.prefix[:4] == b'\x28\xb5\x2f\xfd'
                assert self.prefix[4] & 0xc7 == 0, 'Size/checksum/dictionary flag'
        data = C.create_string_buffer(part)
        source = Buffer(C.cast(data, C.c_void_p), len(part), 0)
        while source.pos < source.size:
            out = Buffer(C.cast(self.output, C.c_void_p), 65536, 0)
            result = self.lib.ZSTD_decompressStream(self.context, C.byref(out), C.byref(source))
            assert not self.lib.ZSTD_isError(result), 'Invalid zstd stream'
            consume(self.output.raw[:out.pos])
            if result == 0:
                self.done = True
                assert source.pos == source.size, 'Trailing frame or tail'
                break

    def close(self):
        self.lib.ZSTD_freeDStream(self.context)
        self.context = None


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def reply(self, status, body=b'', mime='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def event_chunk(self, event):
        self.wfile.write(f'{len(event):x}\r\n'.encode() + event + b'\r\n')
        self.wfile.flush()

    def do_POST(self):
        self.close_connection = True
        decoder = None
        try:
            with self.server.guard:
                index = len(self.server.calls)
                encoding = self.headers.get('Content-Encoding', 'identity')
                self.server.calls.append(encoding)
            case = self.server.case
            self.server.started.set()
            if case in ('stall', 'cancel', 'shutdown', 'capacity'):
                self.server.release.wait(12)
                if case != 'capacity':
                    return
            if case == 'early400' or (case in ('early415', 'twice415') and index == 0):
                self.reply(400 if case == 'early400' else 415)
                return
            if encoding == 'zstd':
                assert self.headers.get_all('Content-Encoding') == ['zstd']
                assert self.headers.get('Content-Length') is None
                assert self.headers.get('Transfer-Encoding') == 'chunked'
                decoder = Decoder()
            else:
                assert encoding == 'identity' and self.headers.get('Transfer-Encoding') is None
                assert self.headers.get('Content-Length') is not None
            assert self.headers.get('Authorization') is None
            assert self.headers.get('Content-Type') == 'application/json'
            offset, chunks = 0, 0
            def compare(part):
                nonlocal offset
                assert part == self.server.expected[offset:offset + len(part)], 'Changed encoded bytes'
                offset += len(part)
            length = int(self.headers.get('Content-Length', 0))
            while True:
                if decoder:
                    size = int(self.rfile.readline().strip(), 16)
                    if size == 0:
                        assert self.rfile.readline() == b'\r\n'
                        break
                else:
                    size = min(65536, length)
                    if not size:
                        break
                # Read each HTTP chunk in bounded pieces, even if AHC coalesces writes.
                remaining = size
                while remaining:
                    part = self.rfile.read(min(65536, remaining))
                    if not part:
                        raise EOFError()
                    remaining -= len(part)
                    if decoder:
                        decoder.feed(part, compare)
                    else:
                        compare(part)
                    chunks += 1
                    if case.startswith('early200') and chunks == 1:
                        # A real duplex HTTP/1 exchange: send headers and an event while
                        # most of the incompressible upload is still backpressured.
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/event-stream')
                        self.send_header('Transfer-Encoding', 'chunked')
                        self.end_headers()
                        first = b'data: ' + wire(dict(type='response.created', response=dict(id=EVENT['response']['id']))) + b'\n\n'
                        self.server.early_event.set()
                        self.event_chunk(first)
                        release = self.server.cancel_release if case == 'early200-cancel' else self.server.release
                        assert release.wait(8), 'Client did not finish the early response step'
                        if case in ('early200-cancel', 'early200-disconnect'):
                            return
                        if case == 'early200-end':
                            self.wfile.write(b'0\r\n\r\n')
                            self.wfile.flush()
                            return
                    if case.startswith('early200'):
                        time.sleep(.005)
                    if case == 'disconnect' and chunks == 1:
                        return
                    if case == 'slow' and offset < len(self.server.expected) - 6 * MIB:
                        time.sleep(.015)
                if decoder:
                    assert self.rfile.read(2) == b'\r\n'
                else:
                    length -= size
            assert offset == len(self.server.expected), (offset, len(self.server.expected))
            assert decoder is None or decoder.done, 'Truncated frame'
            self.server.read_done.set()
            if self.server.measure:
                time.sleep(.25)
            if case == 'silent':
                self.server.release.wait(12)
                return
            if case in ('400', '415', 'twice415', '401', '429', '500'):
                status = 415 if case == 'twice415' else int(case)
                if status != 415 or index == 0 or case == 'twice415':
                    self.reply(status, b'{malformed')
                    return
            if case == 'early200':
                self.event_chunk(b'data: ' + wire(EVENT) + b'\n\n')
                self.wfile.write(b'0\r\n\r\n')
                self.wfile.flush()
            elif case == 'partial':
                self.reply(200, b'data: {"type":"response.created","response":{"id":"resp_synthetic_partial"}}\n\n', 'text/event-stream')
            elif case == 'no-terminal':
                self.reply(200, b'', 'text/event-stream')
            else:
                if self.server.streaming:
                    self.reply(200, b'data: ' + wire(EVENT) + b'\n\n', 'text/event-stream')
                else:
                    self.reply(200, wire(EVENT['response']))
        except (OSError, EOFError):
            pass
        except BaseException as error:
            self.server.errors.append(repr(error))
        finally:
            if decoder:
                decoder.close()


def configuration(server, mode, contract, threshold):
    return dict(principal='synthetic-zstd', keyID='synthetic-key', namespace='synthetic-zstd',
        identity='synthetic-account', keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),
        models=[dict(id='synthetic-order', inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
        reservedMicros=1, upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1',
        upstreamTransport='http', upstreamContract=contract, upstreamRequestCompression=mode,
        upstreamZstdMinimumBytes=threshold, executionTimeoutSeconds=12, firstResponseTimeoutSeconds=2)


def ledger(root):
    with sqlite3.connect(root / 'state/core.sqlite') as db:
        rows = db.execute('SELECT state,outcome_json,usage_json FROM attempts').fetchall()
        health = db.execute('SELECT COUNT(*) FROM account_health').fetchone()[0]
        health += db.execute('SELECT COUNT(*) FROM account_model_health').fetchone()[0]
    return [(state, json.loads(outcome) if outcome else None, json.loads(usage) if usage else None)
            for state, outcome, usage in rows], health


def rss(pid):
    if os.uname().sysname == 'Linux':
        for line in Path(f'/proc/{pid}/status').read_text().splitlines():
            if line.startswith('VmRSS:'):
                return int(line.split()[1]) * 1024
        return 0
    return int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(pid)]).strip() or 0) * 1024


def run(binary, root, request, *, mode='zstd', contract='codex-subscription', threshold=8*MIB,
        case='ok', expected_encoding='zstd', measure=False):
    expected = dict(request)
    if expected.get("parallel_tool_calls", True) is None:
        del expected["parallel_tool_calls"]
    if expected.get("reasoning", {}).get("summary", True) is None:
        expected["reasoning"] = {k: v for k, v in expected["reasoning"].items() if k != "summary"}
    if contract == 'codex-subscription':
        expected['store'] = False
        expected['stream'] = True
        if isinstance(expected['input'], str):
            expected['input'] = [dict(role='user', content=expected['input'])]
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.daemon_threads = True
    server.case, server.calls, server.errors = case, [], []
    server.expected = wire(expected).replace(b'/', b'\\/')
    server.streaming = expected.get("stream", False)
    server.measure = measure
    server.guard = threading.Lock()
    server.started, server.release, server.read_done = threading.Event(), threading.Event(), threading.Event()
    server.cancel_release = threading.Event()
    server.early_event = threading.Event()
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    config = root / 'identity.json'
    settings = configuration(server, mode, contract, threshold)
    if case == "slow":
        settings.update(executionTimeoutSeconds=20)
    if case == "capacity":
        settings.update(executionTimeoutSeconds=20, firstResponseTimeoutSeconds=15)
    config.write_text(json.dumps(settings))
    config.chmod(0o600)
    process = peer = None
    sampler = None
    contenders, contender_results = [], []
    sampling = threading.Event()
    peaks = [0, 0, 0]
    try:
        process, ports = start(binary, config, root)
        if measure:
            baseline = rss(process.pid)
            def sample():
                while not sampling.is_set():
                    try:
                        value = rss(process.pid)
                        peaks[0] = max(peaks[0], value)
                        if server.started.is_set():
                            peaks[1] = max(peaks[1], value)
                        if server.read_done.is_set():
                            peaks[2] = max(peaks[2], value)
                    except (OSError, ValueError, subprocess.CalledProcessError):
                        return
                    sampling.wait(.01)
            sampler = threading.Thread(target=sample)
            sampler.start()
        body = wire(request)
        if case == 'capacity' or case.startswith('early200'):
            def contend():
                conn = http.client.HTTPConnection('127.0.0.1', ports['data'], timeout=20)
                try:
                    conn.request('POST', '/v1/responses', body,
                        {'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json'})
                    response = conn.getresponse()
                    contender_results.append((response.status, response.read()[:100]))
                except BaseException as error:
                    contender_results.append(repr(error))
                finally:
                    conn.close()
        if case == 'capacity':
            for _ in range(4):
                thread = threading.Thread(target=contend)
                thread.start()
                contenders.append(thread)
            deadline = time.monotonic() + 10
            while len(server.calls) < 4:
                assert time.monotonic() < deadline, server.calls
                time.sleep(.01)
            assert server.calls == [expected_encoding] * 4, server.calls
        peer = socket.create_connection(('127.0.0.1', ports['data']), timeout=25)
        begin = time.monotonic()
        peer.sendall((f'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\n'
            f'Content-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n').encode())
        peer.sendall(body)
        if case == 'capacity':
            deadline = time.monotonic() + 8
            while len(server.calls) < 5:
                assert time.monotonic() < deadline, server.calls
                time.sleep(.01)
            assert server.calls == [expected_encoding] * 4 + ['identity'], server.calls
            server.release.set()
        if case in ('cancel', 'shutdown'):
            assert server.started.wait(8)
            time.sleep(.15)
            if case == 'cancel':
                peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                peer.close()
            else:
                process.terminate()
                process.wait(5)
        else:
            response = http.client.HTTPResponse(peer)
            response.begin()
            if case.startswith('early200'):
                assert response.status == 200
                assert response.readline() == b'event: response.created\n'
                assert response.readline().startswith(b'data: ')
                assert response.readline() == b'\n'
                assert server.early_event.is_set() and not server.read_done.is_set()
                if case == 'early200-cancel':
                    response.close()
                    peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                    peer.close()
                else:
                    server.release.set()
            if case == 'early200-cancel':
                result = b''
            else:
                result = response.read()
            if case == 'early200':
                assert server.read_done.is_set() and b'response.completed' in result, (result[:200], server.errors)
            elif case.startswith('early200'):
                assert b'response.completed' not in result
            elif case in ('ok', 'slow', '415', 'early415', 'capacity'):
                assert response.status == 200, (response.status, result[:200], server.errors)
            elif case in ('400', 'early400', 'twice415'):
                assert response.status == (415 if case == 'twice415' else 400), (response.status, result[:200], server.errors)
            elif case in ('stall', 'silent'):
                assert response.status == 504, (response.status, result[:200], server.errors)
                code = b'execution_deadline_exceeded' if case == 'stall' else b'execution_first_response_timeout'
                assert code in result
            else:
                assert response.status in (429, 502, 503), (response.status, result[:200], server.errors)
        if case != 'shutdown':
            deadline = time.monotonic() + 3
            while True:
                rows, health = ledger(root)
                if rows and rows[0][0] != 'intent':
                    break
                assert time.monotonic() < deadline, rows
                time.sleep(.02)
            if case == 'capacity':
                for thread in contenders:
                    thread.join(8)
                assert len(contender_results) == 4 and all(r[0] == 200 for r in contender_results), contender_results
                rows, health = ledger(root)
            assert len(rows) == (5 if case == 'capacity' else 1), rows
            state, outcome, usage = rows[0]
            if case in ('ok', 'slow', '415', 'early415', 'capacity', 'early200'):
                assert state == 'settled' and outcome['kind'] == 'succeeded', rows
            elif case in ('400', 'early400', 'twice415', '401', '429'):
                assert state == 'settled' and outcome['kind'] == 'failed', rows
                assert usage['inputTokens'] == 0 and usage['completeness'] == 'complete', rows
            else:
                assert state == 'unknown' and usage is None, rows
                if case in ('stall', 'silent', 'cancel', 'early200-cancel'):
                    assert outcome['failure'] == ('client_cancelled' if case in ('cancel', 'early200-cancel') else 'deadline_exceeded'), rows
            if case == 'early200-cancel':
                # Let the downstream RST determine the ledger outcome before
                # allowing the fixture to also disconnect the upstream socket.
                server.cancel_release.set()
            if case not in ('401', '429', '500'):
                assert health == 0, health
        expected_calls = [expected_encoding]
        if case in ('415', 'early415', 'twice415') and expected_encoding == 'zstd':
            expected_calls.append('identity')
        if case == "capacity":
            expected_calls = [expected_encoding] * 4 + ["identity"]
        assert server.calls == expected_calls, server.calls
        upload_bytes = len(server.expected)
        if case.startswith('early200'):
            # Hold four follow-up uploads concurrently: even one leaked reservation
            # makes a request fall back to identity. One successful probe is insufficient.
            server.case = 'capacity'
            # Stay within the independent 48 MiB inbound body budget with four
            # backpressured probes; the original request remains near 30 MiB.
            probe = dict(request, input=request['input'][:9*MIB])
            body = wire(probe)
            server.expected = wire(dict(expected, input=[dict(role='user', content=probe['input'])])).replace(b'/', b'\\/')
            server.release.clear()
            for _ in range(4):
                thread = threading.Thread(target=contend)
                thread.start()
                contenders.append(thread)
            deadline = time.monotonic() + 8
            while len(server.calls) < 5:
                assert time.monotonic() < deadline, server.calls
                time.sleep(.01)
            assert server.calls[1:] == [expected_encoding] * 4, server.calls
            server.release.set()
            for thread in contenders:
                thread.join(10)
            assert len(contender_results) == 4 and all(r[0] == 200 for r in contender_results), contender_results
        assert not server.errors, server.errors
        server.release.set()
        if process.poll() is None:
            process.terminate()
            if measure:
                _, status, usage = os.wait4(process.pid, 0)
                process.returncode = os.waitstatus_to_exitcode(status)
                # Darwin reports bytes; Linux reports KiB. Kernel high water avoids
                # missing transient JSON peaks between process RSS samples.
                high_water = int(usage.ru_maxrss) * (1 if os.uname().sysname == 'Darwin' else 1024)
                peaks[0] = max(peaks[0], high_water)
            else:
                process.wait(5)
        logs = process.stdout.read()
        uploads = [line for line in logs.splitlines() if b'Upstream request upload' in line]
        if len(server.expected) > 8*MIB:
            assert len(uploads) == len(server.calls), uploads
            for encoding in set(server.calls):
                assert sum(f'content_encoding={encoding}'.encode() in line for line in uploads) == server.calls.count(encoding), uploads
            for line in uploads:
                assert b'wire_size_bucket=' in line and b'compression_duration_bucket=' in line
            if case == 'early200':
                assert b'result=sent' in uploads[0], uploads
                if mode == 'off':
                    limits = ((1, 'at_most_1_mib'), (4, '1_to_4_mib'),
                              (8, '4_to_8_mib'), (16, '8_to_16_mib'),
                              (24, '16_to_24_mib'), (32, '24_to_32_mib'))
                    bucket = next((name for limit, name in limits if upload_bytes <= limit*MIB), 'over_32_mib')
                    assert f'wire_size_bucket={bucket}'.encode() in uploads[0], uploads
            if case in ('cancel', 'stall', 'early415', 'early400', 'shutdown',
                        'early200-cancel', 'early200-disconnect', 'early200-end'):
                assert b'result=interrupted' in uploads[0], uploads
        assert TOKEN.encode() not in logs and b'synthetic-payload-' not in logs
        elapsed = time.monotonic() - begin
        print(f'PASS: zstd/{mode}/{contract}/{case}: {len(server.calls)} dispatch, bytes/framing, ledger, health, cleanup ({elapsed:.2f}s)', flush=True)
        if measure:
            return dict(baseline=baseline, peak=peaks[0], upload_peak=peaks[1], held_peak=peaks[2])
    except BaseException:
        if process:
            dump_gateway_failure(process)
        raise
    finally:
        sampling.set()
        if sampler:
            sampler.join(2)
        if peer:
            peer.close()
        server.release.set()
        server.cancel_release.set()
        if process:
            stop(process)
        server.shutdown()
        server.server_close()
        worker.join(2)
        for thread in contenders:
            thread.join(3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--memory-output', type=Path)
    args = parser.parse_args()
    binary = str(args.binary.resolve())
    # Prove the verifier fails on truncated and trailing frames using a known empty frame.
    frame = bytes.fromhex('28b52ffd0000010000')
    decoder = Decoder()
    decoder.feed(frame, lambda _: None)
    assert decoder.done
    try:
        decoder.feed(frame, lambda _: None)
        raise RuntimeError('Extra frame was accepted')
    except AssertionError:
        pass
    decoder.close()
    decoder = Decoder()
    decoder.feed(frame[:-1], lambda _: None)
    assert not decoder.done
    decoder.close()
    with tempfile.TemporaryDirectory(prefix='codexone-zstd-') as temporary:
        root = Path(temporary)
        count = 0
        def check(request, **options):
            nonlocal count
            directory = root / str(count)
            count += 1
            directory.mkdir()
            return run(binary, directory, request, **options)
        if args.memory_output:
            results = []
            for shape in ('repeated', 'random', 'base64'):
                rng = random.Random(123456789)
                if shape == 'repeated':
                    text = 'x' * (30*MIB)
                elif shape == 'random':
                    text = rng.randbytes(30*MIB).translate(bytes.maketrans(bytes(range(256)),
                        bytes(33 + i % 90 for i in range(256)))).decode('ascii').replace('"', 'a').replace('\\', 'b')
                else:
                    text = base64.b64encode(rng.randbytes(30*MIB//4*3)).decode()
                request = dict(model='synthetic-order', input='synthetic-payload-' + text, stream=False)
                for repeat in range(3):
                    for mode in ('off', 'zstd'):
                        result = check(request, mode=mode, measure=True,
                            expected_encoding='identity' if mode == 'off' else 'zstd')
                        results.append(dict(shape=shape, repeat=repeat, mode=mode, **result))
            request = dict(model='synthetic-order', input=base64.b64encode(random.Random(123456789).randbytes(6*MIB)).decode(), stream=False)
            for repeat in range(3):
                for mode in ('off', 'zstd'):
                    result = check(request, mode=mode, measure=True, case='capacity',
                        expected_encoding='identity' if mode == 'off' else 'zstd')
                    results.append(dict(shape='concurrent-4-plus-1', repeat=repeat, mode=mode, **result))
            args.memory_output.write_text(json.dumps(results, indent=2) + '\n')
            return
        request = dict(REQUEST, reasoning={'effort': 'low'}, stream=False, input='synthetic-payload-' + 'x' * (9*MIB))
        request.pop('parallel_tool_calls', None)
        expected = dict(request, input=[dict(role='user', content=request['input'])], store=False, stream=True)
        size = len(wire(expected))
        for threshold in (size-1, size, size+1):
            check(request, threshold=threshold, expected_encoding='zstd' if threshold < size else 'identity')
        check(dict(request, stream=True))
        rng = random.Random(123456789)
        large = dict(model='synthetic-order', input=base64.b64encode(rng.randbytes(21*MIB)).decode(), stream=False)
        check(dict(large, input=large['input'][:9*MIB]), case='capacity')
        check(request, mode='off', expected_encoding='identity')
        check(request, contract='responses', expected_encoding='identity')
        # Fast failure/lifecycle matrix; all requests still use the actual binary and sockets.
        for case in ('ok', '400', '415', 'early400', 'early415', 'twice415', '401', '429',
                     '500', 'disconnect', 'no-terminal', 'partial', 'silent'):
            check(request, case=case)
        # Incompressible data forces actual backpressure instead of a tiny compressed upload.
        for case in ('early200', 'early200-cancel', 'early200-disconnect', 'early200-end'):
            check(dict(large, stream=True), case=case)
        for case in ('early200', 'early200-disconnect'):
            check(dict(large, stream=True), case=case, mode='off', expected_encoding='identity')
        for case in ('slow', 'stall', 'cancel', 'shutdown'):
            check(large, case=case)
        print('PASS: synthetic upstream zstd process matrix; no real provider contacted')


if __name__ == '__main__':
    main()
