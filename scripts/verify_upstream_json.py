#!/usr/bin/env python3
"""Synthetic socket diagnostic; no live credentials, cache claims, or saved payloads."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import time

from verify_protocol import TOKEN, connect, start, stop
from verify_text_contract import FIXTURE, Provider as WireProvider, rows
from verify_websocket import dial, receive, send


class Provider(WireProvider):
    def sequence(self, request):
        assert self.headers.get('Authorization') is None
        with self.server.guard:
            self.server.received.append((request, dict(self.headers)))
            index = len(self.server.received)
        events = json.loads(self.server.literal.replace('resp_contract_1', f'resp_contract_{index}')
                           .replace('msg_contract_1', f'msg_contract_{index}'))
        details = {'cache_write_tokens': 1024}
        counter = self.server.counter
        if counter != 'missing':
            details['cached_tokens'] = counter
        events[-1]['response']['usage'] = {
            'input_tokens': 8192, 'output_tokens': 3, 'total_tokens': 8195,
            'input_tokens_details': details,
        }
        return events


def digest(value, *, canonical):
    return hashlib.sha256(json.dumps(value, sort_keys=canonical,
                                    separators=(',', ':')).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--require-stable', action='store_true')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.guard = threading.Lock()
    server.received = []
    server.literal = json.dumps(json.loads(FIXTURE.read_text())['events'])
    server.counter = 0
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    tools = [dict(type='function', name=f'synthetic_tool_{i}', description='Synthetic tool',
                  parameters=dict(type='object', properties={
                      'alpha': dict(type='string', description='First'),
                      'beta': dict(type='integer', description='Second'),
                      'gamma': dict(type='boolean')}, required=['alpha', 'beta'],
                      additionalProperties=False), strict=True) for i in range(116)]
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-prefix-') as temporary:
            for transport in ('http', 'websocket'):
                for route in (('json', 'sse', 'native') if transport == 'websocket' else ('json', 'sse')):
                    root = Path(temporary) / f'{transport}-{route}'
                    root.mkdir(mode=0o700)
                    config = root / 'identity.json'
                    config.write_text(json.dumps(dict(
                        principal='synthetic-prefix', keyID='synthetic-key',
                        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),
                        namespace='synthetic-prefix', identity='synthetic-identity',
                        models=[dict(id='synthetic-contract', inputMicrosPerMillion=0,
                                     outputMicrosPerMillion=0)], reservedMicros=1,
                        upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1',
                        upstreamTransport=transport, upstreamContract='codex-subscription')))
                    config.chmod(0o600)
                    process, ports = start(str(args.binary.resolve()), config, root)
                    peer = None
                    try:
                        if route == 'native':
                            peer = dial(ports['data'], headers={'session-id': 'synthetic-session'})
                        history = []
                        ordered, canonical = set(), set()
                        # Exercise real zero, nonzero, absent, and malformed upstream counters.
                        counters = [0, 2048, 'missing', 'invalid', 0]
                        for turn, counter in enumerate(counters):
                            server.counter = counter
                            history.append(dict(role='user', content=f'Synthetic turn {turn}'))
                            request = dict(model='synthetic-contract', input=history,
                                           instructions='Stable synthetic instructions.', tools=tools,
                                           prompt_cache_key='synthetic-cache', max_output_tokens=None,
                                           reasoning={'effort': 'medium'}, stream=route == 'sse')
                            before = len(server.received)
                            if peer is not None:
                                send(peer, {'type': 'response.create', **request}, masked=True)
                                for _ in range(20):
                                    opcode, body = receive(peer)
                                    assert opcode == 1
                                    event = json.loads(body)
                                    if event.get('type') in ('response.completed', 'error'):
                                        break
                                else:
                                    raise AssertionError('No terminal event')
                                assert event['type'] == 'response.completed', event['type']
                                status = 200
                            else:
                                status, body = connect(ports['data'], 'POST', '/v1/responses', request,
                                                       client_headers={'session-id': 'synthetic-session'})
                            assert status == 200, (transport, route, status)
                            assert len(server.received) == before + 1, 'Unexpected replay'
                            wire, headers = server.received[-1]
                            assert {k.lower(): v for k, v in headers.items()}['session-id'] == 'synthetic-session'
                            assert wire['prompt_cache_key'] == request['prompt_cache_key']
                            assert wire['instructions'] == request['instructions']
                            assert wire['tools'] == tools and wire['input'] == history
                            assert wire['model'] == request['model'] and wire['reasoning'] == request['reasoning']
                            assert 'max_output_tokens' not in wire
                            ordered.add(digest(wire['tools'], canonical=False))
                            canonical.add(digest(wire['tools'], canonical=True))
                            response = (event['response'] if route == 'native' else
                                        json.loads(body) if route == 'json' else
                                        [json.loads(line[6:]) for line in body.splitlines()
                                         if line.startswith(b'data: ') and line[6:] != b'[DONE]'][-1]['response'])
                            details = response['usage']['input_tokens_details']
                            assert details['cache_write_tokens'] == 1024
                            if isinstance(counter, int):
                                assert details['cached_tokens'] == counter
                            else:
                                assert 'cached_tokens' not in details, 'Missing/invalid counter fabricated'
                            deadline = time.monotonic() + 5
                            while True:
                                ledger = rows(root)
                                if len(ledger) == turn + 1 and ledger[-1][2] is not None:
                                    break
                                assert time.monotonic() < deadline, 'Finalization timed out'
                                time.sleep(.02)
                            usage = ledger[-1][2]
                            assert usage['cachedTokens'] == (counter if isinstance(counter, int) else 0)
                            assert usage['completeness'] == ('complete' if isinstance(counter, int) else 'partial')
                            history.append(dict(role='assistant', content='Synthetic reply'))
                        assert len(canonical) == 1
                        print(f'PASS {transport}/{route}: metadata, append-only semantics, usage and ledger; '
                              f'tool_order_variants={len(ordered)} canonical_variants={len(canonical)}', flush=True)
                        if args.require_stable:
                            assert len(ordered) == 1, 'Upstream tool object order changed'
                    finally:
                        if peer is not None:
                            peer.close()
                        stop(process)
    finally:
        server.shutdown()
        server.server_close()
        worker.join(10)


if __name__ == '__main__':
    main()
