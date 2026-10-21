#!/usr/bin/env python3
"""Optional actual Codex CLI smoke through the gateway using private temp state and synthetic I/O."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
from verify_protocol import TOKEN, start, stop, latest

GUIDANCE = 'Synthetic fixture coding guidance: follow the user request and execute only the requested local test command.'


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        assert 0 <= length <= 524288
        document = json.loads(self.rfile.read(length))
        assert self.path == '/v1/responses' and document['model'] == 'synthetic-text'
        assert self.headers.get('Authorization') is None
        has_guidance = any(item.get('role') == 'developer' and GUIDANCE in json.dumps(item.get('content'))
                           for item in document.get('input', []))
        assert has_guidance == self.server.profile_supplied, 'Configured authoritative model guidance was not adopted'
        with self.server.guard:
            self.server.calls += 1
            index = self.server.calls
        assert index <= 2, 'Synthetic client unexpectedly repeated a turn'
        assert not any(tool['type'] == 'web_search' for tool in document.get('tools', []))
        retry_probe = self.server.retry_probe
        if index == 1 and not retry_probe:
            item = {'type': 'function_call', 'id': 'fc_synthetic_cli', 'name': 'exec_command',
                    'call_id': 'call_synthetic_cli', 'arguments': json.dumps({'cmd': 'printf synthetic-tool-success', 'shell': '/bin/sh', 'login': False, 'max_output_tokens': 64})}
        else:
            results = [item for item in document['input'] if item.get('type') == 'function_call_output']
            if not retry_probe:
                assert any(item['call_id'] == 'call_synthetic_cli' and 'synthetic-tool-success' in item['output'] for item in results)
                assert any(item.get('type') == 'reasoning' and item.get('encrypted_content') == 'synthetic-cli-reasoning-cipher' for item in document['input'])
            item = {'type': 'message', 'id': 'msg_synthetic_cli', 'role': 'assistant', 'phase': 'final_answer',
                    'status': 'completed', 'content': [{'type': 'output_text', 'text': 'synthetic client acceptance', 'annotations': []}]}
        items = [item]
        if index == 1 and not retry_probe:
            items.insert(0, {'type': 'reasoning', 'id': 'rs_synthetic_cli', 'summary': [], 'encrypted_content': 'synthetic-cli-reasoning-cipher'})
        response = {'id': f'resp_synthetic_cli_{index}', 'object': 'response', 'model': 'synthetic-text',
                    'status': 'completed', 'output': items, 'usage': {'input_tokens': 5, 'output_tokens': 3,
                    'total_tokens': 8, 'input_tokens_details': {'cached_tokens': 0}}}
        events = [{'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'output': [], 'usage': None}}]
        events += [{'type': 'response.output_item.done', 'output_index': index, 'item': item} for index, item in enumerate(items)]
        events.append({'type': 'response.completed', 'response': response})
        if retry_probe and index == 1:
            # A response ID was exposed; the provider then closes without a terminal or usage.
            events = events[:1]
        body = ''.join('data: ' + json.dumps(event) + '\n\n' for event in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--retry-probe', action='store_true', help='Show that a client reconnect creates a new execution after EOF')
    parser.add_argument('--without-profile', action='store_true', help='Verify that directory failure can still cause client fallback')
    args = parser.parse_args()
    codex = shutil.which(args.codex)
    assert codex is not None, 'Codex CLI is required for this optional check'
    version = subprocess.check_output([codex, '--version'], text=True, timeout=10).strip()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.daemon_threads = True
    server.guard = threading.Lock()
    server.calls = 0
    server.retry_probe = args.retry_probe
    server.profile_supplied = not args.without_profile
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-client-') as temporary:
            root = Path(temporary)
            configuration = root / 'identity.json'
            configuration.write_text(json.dumps({'principal': 'synthetic-principal', 'keyID': 'synthetic-key',
                'keySHA256': hashlib.sha256(TOKEN.encode()).hexdigest(), 'namespace': 'synthetic-provider',
                'identity': 'synthetic-account', 'reservedMicros': 10,
                'models': [{'id': 'synthetic-text', 'inputMicrosPerMillion': 1000000, 'outputMicrosPerMillion': 1000000,
                            'catalog': {'baseInstructions': GUIDANCE} if server.profile_supplied else None}],
                'upstreamBaseURL': f'http://127.0.0.1:{server.server_port}/v1'}))
            configuration.chmod(0o600)
            process, ports = start(str(args.binary.resolve()), configuration, root)
            try:
                client = root / 'client'
                client.mkdir(mode=0o700)
                work = root / 'work'
                work.mkdir()
                (client / 'config.toml').write_text(f'''model_provider = "synthetic"
model = "synthetic-text"
web_search = "disabled"
[features]
api_key_model_discovery = true
[model_providers.synthetic]
name = "Synthetic local fixture"
base_url = "http://127.0.0.1:{ports['data']}/v1"
model_catalog_url = "http://127.0.0.1:{ports['data']}/v1/models"
wire_api = "responses"
env_key = "CODEXONE_SYNTHETIC_CLIENT_KEY"
requires_openai_auth = false
stream_max_retries = 1
request_max_retries = 0
''')
                result = subprocess.run([codex, 'exec', '--ephemeral', '--skip-git-repo-check', '--json', '--sandbox', 'read-only',
                    'Return synthetic client acceptance without tools.' if args.retry_probe else
                    'Use exec_command once to print synthetic-tool-success, then report synthetic client acceptance.'],
                    cwd=work, env={'PATH': os.defpath, 'CODEX_HOME': str(client), 'CODEXONE_SYNTHETIC_CLIENT_KEY': TOKEN},
                    capture_output=True, timeout=40)
                events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith(b'{')]
                assert result.returncode == 0, {'exit': result.returncode, 'event_types': [event.get('type') for event in events], 'errors': [event.get('message', '')[:350] for event in events if event.get('type') == 'error'], 'provider_calls': server.calls}
                assert b'synthetic client acceptance' in result.stdout and server.calls == 2
                metadata_fallback = b'Model metadata for' in result.stdout + result.stderr
                assert metadata_fallback == args.without_profile, 'Unexpected model catalog acceptance/fallback'
                assert any(event.get('type') == 'turn.completed' for event in events)
                latest(root / 'state/core.sqlite', 'settled')
                with sqlite3.connect(root / 'state/core.sqlite') as db:
                    rows = db.execute('SELECT state,usage_json FROM attempts ORDER BY rowid').fetchall()
                for file in (root / 'state').glob('core.sqlite*'):
                    assert GUIDANCE.encode() not in file.read_bytes(), 'Model guidance leaked into core storage'
                if args.retry_probe:
                    assert [state for state, _ in rows] == ['unknown', 'settled'] and rows[0][1] is None
                    assert b'Reconnecting' in result.stdout
                    print(f'PASS: {version} reconnect after exposed response ID/EOF creates a second execution; first remains unknown, second settled; no output-recovery claim')
                else:
                    assert len(rows) == 2 and all(state == 'settled' for state, _ in rows)
                    assert all(json.loads(usage)['inputTokens'] == 5 for _, usage in rows)
                    if args.without_profile:
                        print(f'PASS: {version} unavailable Codex catalog can cause client fallback and generation; explicitly not accepted as model catalog compatibility')
                    else:
                        print(f'PASS: {version} explicit authoritative model guidance adopted without fallback; actual text/client function/result loop; two durable settlements; private temporary client state')
            finally:
                stop(process)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


if __name__ == '__main__':
    main()
