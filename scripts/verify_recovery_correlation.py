#!/usr/bin/env python3
"""Actual CLI experiment; volatile fixture replay is deliberately NOT production recovery."""
import argparse
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
from verify_client import GUIDANCE
from verify_protocol import TOKEN, start, stop, latest

TEXT = 'synthetic correlation acceptance'
PROMPT = 'Return synthetic correlation acceptance without using tools.'


def events(index):
    item = {'type': 'message', 'id': f'msg_correlation_{index}', 'role': 'assistant',
            'phase': 'final_answer', 'status': 'completed',
            'content': [{'type': 'output_text', 'text': TEXT, 'annotations': []}]}
    response = {'id': f'resp_correlation_{index}', 'object': 'response', 'model': 'synthetic-text',
                'status': 'completed', 'output': [item],
                'usage': {'input_tokens': 5, 'output_tokens': 3, 'total_tokens': 8, 'input_tokens_details': {'cached_tokens': 0}}}
    return [{'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'output': [], 'usage': None}},
            {'type': 'response.output_item.added', 'output_index': 0, 'item': {**item, 'status': 'in_progress', 'content': []}},
            {'type': 'response.content_part.added', 'item_id': item['id'], 'output_index': 0, 'content_index': 0,
             'part': {'type': 'output_text', 'text': '', 'annotations': []}},
            {'type': 'response.output_text.delta', 'item_id': item['id'], 'output_index': 0, 'content_index': 0, 'delta': TEXT},
            {'type': 'response.output_text.done', 'item_id': item['id'], 'output_index': 0, 'content_index': 0, 'text': TEXT},
            {'type': 'response.content_part.done', 'item_id': item['id'], 'output_index': 0, 'content_index': 0, 'part': item['content'][0]},
            {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
            {'type': 'response.completed', 'response': response}]


class OwnedServer(ThreadingHTTPServer):
    daemon_threads = False
    def __init__(self, handler):
        super().__init__(('127.0.0.1', 0), handler)
        self.guard = threading.Lock()
        self.failures = []
        self.records = []
        self.calls = self.replays = 0
        self.thread = threading.Thread(target=self.serve_forever)
    def __enter__(self):
        self.thread.start()
        return self
    def __exit__(self, *_):
        self.shutdown()
        self.server_close()
        self.thread.join(3)
        assert not self.thread.is_alive() and not self.failures, ('Fixture owner failed', self.failures)


class Base(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def do_GET(self): self.handle_owned()
    def do_POST(self): self.handle_owned()
    def handle_owned(self):
        self.connection.settimeout(15)
        try: self.respond()
        except Exception as exc:
            with self.server.guard: self.server.failures.append(type(exc).__name__)
            self.close_connection = True
    def body(self):
        n = int(self.headers.get('Content-Length', '0'))
        assert 0 <= n <= 524288
        b = self.rfile.read(n)
        assert len(b) == n
        return b
    def reply(self, status, body, content='application/json', truncated=False):
        self.send_response(status)
        self.send_header('Content-Type', content)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if truncated:
            blocks = body.split(b'\n\n')
            count = 4 if self.server.case == 'prefix' else 1
            self.wfile.write(b'\n\n'.join(blocks[:count]) + b'\n\n')
        else: self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True


class Provider(Base):
    def respond(self):
        assert self.command == 'POST' and self.path == '/v1/responses'
        document = json.loads(self.body())
        assert document['model'] == 'synthetic-text'
        with self.server.guard:
            self.server.calls += 1
            n = self.server.calls
        assert n <= 2
        b = b''.join(('data: ' + json.dumps(e) + '\n\n').encode() for e in events(n))
        self.reply(200, b, 'text/event-stream')


class Relay(Base):
    def respond(self):
        s = self.server
        b = self.body()
        if self.headers.get('Authorization') != 'Bearer ' + TOKEN:
            self.reply(401, b'{"error":{"message":"fixture authorization denied"}}')
            return
        is_create = self.command == 'POST' and self.path == '/v1/responses'
        if is_create:
            record = {'body': json.loads(b), 'headers': {k.lower(): v for k, v in self.headers.items()
                      if k.lower() not in ('authorization', 'host', 'content-length')}}
            with s.guard:
                s.records.append(record)
                n = len(s.records)
            assert n <= 3
            if n == 2:
                # Explicit test step, NOT a proposed request-identity heuristic.
                if s.case in ('revoked', 'epoch'):
                    self.reply(401 if s.case == 'revoked' else 409,
                               b'{"error":{"message":"fixture replay scope invalid"}}')
                    return
                s.replays += 1
                self.reply(200, s.cached, 'text/event-stream')
                return
        c = http.client.HTTPConnection('127.0.0.1', s.gateway, timeout=15)
        try:
            c.request(self.command, self.path, body=b or None,
                      headers={'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json'})
            r = c.getresponse()
            data = r.read(8 * 1024 * 1024 + 1)
            assert len(data) <= 8 * 1024 * 1024
            status, content = r.status, r.getheader('Content-Type', 'application/json')
        finally: c.close()
        if is_create and n == 1:
            assert status == 200
            parsed = [json.loads(line[6:]) for line in data.splitlines() if line.startswith(b'data: ') and line[6:] != b'[DONE]']
            terminal = [e for e in parsed if e.get('type') == 'response.completed']
            assert len(terminal) == 1 and terminal[0]['response']['status'] == 'completed'
            assert terminal[0]['response']['usage']['input_tokens_details']['cached_tokens'] == 0
            # HTTP EOF is not a persistence barrier: finalization has its own owner.
            latest(s.database, 'settled')
            s.cached = data
            self.reply(status, data, content, truncated=True)
        else: self.reply(status, data, content)


def compare(a, b):
    result = {}
    for section in ('body', 'headers'):
        x, y = a[section], b[section]
        result[section + 'Equal'] = x == y
        result[section + 'ChangedFields'] = sorted(k for k in x.keys() | y.keys() if x.get(k) != y.get(k))
    # Only presence/equality; no identifier or synthetic body values are reported.
    for key in ('session_id', 'session-id', 'thread-id', 'x-codex-turn-state', 'x-codex-turn-metadata', 'x-request-id'):
        result[key] = {'present': key in a['headers'], 'equal': a['headers'].get(key) == b['headers'].get(key)}
    return result


def run_case(binary, codex, case):
    with tempfile.TemporaryDirectory(prefix='codexone-correlation-') as temporary:
        root = Path(temporary)
        with OwnedServer(Provider) as provider:
            config = root / 'identity.json'
            config.write_text(json.dumps({'principal': 'synthetic-principal', 'keyID': 'synthetic-key',
                'keySHA256': hashlib.sha256(TOKEN.encode()).hexdigest(), 'namespace': 'synthetic-provider',
                'identity': 'synthetic-account', 'reservedMicros': 10,
                'models': [{'id': 'synthetic-text', 'inputMicrosPerMillion': 1000000,
                            'outputMicrosPerMillion': 1000000, 'catalog': {'baseInstructions': GUIDANCE}}],
                'upstreamBaseURL': f'http://127.0.0.1:{provider.server_port}/v1'}))
            config.chmod(0o600)
            gateway, ports = start(str(binary), config, root)
            try:
                with OwnedServer(Relay) as relay:
                    relay.gateway, relay.case = ports['data'], case
                    relay.database = root/'state/core.sqlite'
                    home, work = root/'client', root/'work'
                    home.mkdir(mode=0o700); work.mkdir(mode=0o700)
                    (home/'config.toml').write_text(f'''model_provider = "synthetic"
model = "synthetic-text"
web_search = "disabled"
sandbox_mode = "read-only"
[features]
api_key_model_discovery = true
[model_providers.synthetic]
name = "Synthetic correlation fixture"
base_url = "http://127.0.0.1:{relay.server_port}/v1"
model_catalog_url = "http://127.0.0.1:{relay.server_port}/v1/models"
wire_api = "responses"
env_key = "CODEXONE_SYNTHETIC_CLIENT_KEY"
requires_openai_auth = false
supports_websockets = false
stream_max_retries = 1
request_max_retries = 0
''')
                    def client(resume=False):
                        command = [codex, 'exec'] + (['resume', '--last'] if resume else ['--sandbox', 'read-only'])
                        r = subprocess.run(command + ['--skip-git-repo-check', '--json', PROMPT], cwd=work,
                            env={'PATH': os.defpath, 'CODEX_HOME': str(home), 'CODEXONE_SYNTHETIC_CLIENT_KEY': TOKEN},
                            capture_output=True, timeout=45)
                        lines = [json.loads(l) for l in r.stdout.splitlines() if l.startswith(b'{')]
                        return r, lines
                    first, output = client()
                    assert len(relay.records) == 2 and provider.calls == 1, 'Expected one retry and one upstream execution'
                    latest(root/'state/core.sqlite', 'settled')
                    if case in ('revoked', 'epoch'):
                        assert first.returncode != 0 and relay.replays == 0
                    else:
                        assert first.returncode == 0 and relay.replays == 1, {'case': case, 'eventTypes': [e['type'] for e in output]}
                        messages = [e['item']['text'] for e in output if e.get('type') == 'item.completed' and e.get('item', {}).get('type') == 'agent_message']
                        assert messages == [TEXT], 'Replayed text must produce one final message'
                        second, later = client(resume=True)
                        assert second.returncode == 0 and len(relay.records) == 3 and provider.calls == 2
                        assert any(e.get('type') == 'turn.completed' for e in later)
                    # A different credential must not read the fixture cache or dispatch anything.
                    before = (provider.calls, relay.replays, len(relay.records))
                    c = http.client.HTTPConnection('127.0.0.1', relay.server_port, timeout=5)
                    try:
                        c.request('POST', '/v1/responses', b'{}', {'Authorization': 'Bearer synthetic-other-subject'})
                        denied = c.getresponse(); assert denied.status == 401; denied.read()
                    finally: c.close()
                    assert before == (provider.calls, relay.replays, len(relay.records))
                    with sqlite3.connect(root/'state/core.sqlite') as db:
                        rows = db.execute('SELECT state FROM attempts ORDER BY rowid').fetchall()
                    assert rows == [('settled',)] * provider.calls
                    result = {'case': case, 'retry': compare(*relay.records[:2]), 'upstreamExecutions': provider.calls,
                              'gatewaySettledAttempts': len(rows), 'fixtureReplays': relay.replays,
                              'fixtureScopeDenial': True, 'finalMessages': 1 if first.returncode == 0 else 0}
                    if len(relay.records) == 3: result['activeIdenticalNewTurn'] = compare(relay.records[0], relay.records[2])
                    return result
            finally: stop(gateway)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--codex', default='codex')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    assert not args.output.exists(), 'Use a new report path'
    codex = shutil.which(args.codex); assert codex
    version = subprocess.check_output([codex, '--version'], text=True, timeout=10).strip()
    results = [run_case(args.binary.resolve(), codex, c) for c in ('created', 'prefix', 'revoked', 'epoch')]
    report = {'client': version, 'experimentOnly': True, 'productionRecoveryImplemented': False,
              'fixtureGuardsAreNotProductAuthorizationProof': True,
              'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'results': results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print('PASS: actual CLI text replay/correlation experiment; fixture only, no production recovery claim')


if __name__ == '__main__': main()
