#!/usr/bin/env python3
"""Private-context ownership and standalone compaction against bounded synthetic HTTP sockets."""
import argparse
import copy
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
from verify_protocol import TOKEN, Upstream, connect, start, stop, latest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
    provider.daemon_threads = True
    provider.guard = threading.Lock()
    provider.calls = 0
    provider.stalled = threading.Event()
    provider.cancelled = threading.Event()
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-context-') as temporary:
            root = Path(temporary)
            configuration = root / 'identity.json'
            profile = {'principal': 'synthetic-principal', 'keyID': 'synthetic-key',
                'keySHA256': hashlib.sha256(TOKEN.encode()).hexdigest(), 'namespace': 'synthetic-provider',
                'identity': 'synthetic-account', 'reservedMicros': 10,
                'models': [{'id': 'synthetic-text', 'inputMicrosPerMillion': 1000000, 'outputMicrosPerMillion': 1000000}],
                'upstreamBaseURL': f'http://127.0.0.1:{provider.server_port}/v1'}
            configuration.write_text(json.dumps(profile))
            configuration.chmod(0o600)
            binary = str(args.binary.resolve())
            process, ports = start(binary, configuration, root)
            db_path = root / 'state/core.sqlite'
            try:
                port = ports['data']
                status, body = connect(port, 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'reasoning', 'include': ['reasoning.encrypted_content']})
                assert status == 200
                original = json.loads(body)['output']
                continuation = {'model': 'synthetic-text', 'input': original + [{'role': 'user', 'content': 'next'}]}
                assert connect(port, 'POST', '/v1/responses', continuation)[0] == 200
                latest(db_path, 'settled')
                count = provider.calls
                forged = copy.deepcopy(continuation)
                forged['input'][0]['encrypted_content'] += '-forged'
                assert connect(port, 'POST', '/v1/responses', forged)[0] == 400
                assert provider.calls == count
                for prefix in ('/v1', '/backend-api/codex'):
                    status, body = connect(port, 'POST', prefix + '/responses/compact', continuation)
                    assert status == 200
                    compact = json.loads(body)
                    assert compact['object'] == 'response.compaction' and len(compact['output']) == 3 and compact['output'][1] == original[0]
                    assert latest(db_path, 'settled')['estimatedMicros'] == 8
                    status, _body = connect(port, 'POST', prefix + '/responses', {'model': 'synthetic-text', 'input': compact['output'] + [{'role': 'user', 'content': 'continue compacted window'}]})
                    assert status == 200
                    assert connect(port, 'POST', prefix + '/responses', {'model': 'synthetic-text', 'input': 'text', 'previous_response_id': compact['id']})[0] == 400
                for prompt, tools in (
                    ('tool-namespace', [{'type': 'namespace', 'name': 'synthetic_ns', 'tools': [{'type': 'function', 'name': 'local_tool', 'parameters': {'type': 'object'}}]}]),
                    ('tool-custom', [{'type': 'custom', 'name': 'local_custom', 'format': {'type': 'text'}}]),
                ):
                    status, body = connect(port, 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': prompt, 'tools': tools})
                    assert status == 200
                    call = json.loads(body)['output'][0]
                    result_type = 'custom_tool_call_output' if call['type'] == 'custom_tool_call' else 'function_call_output'
                    status, _body = connect(port, 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': [call, {'type': result_type, 'id': 'client-local-result', 'call_id': call['call_id'], 'output': 'synthetic result'}]})
                    assert status == 200
                with sqlite3.connect(db_path) as db:
                    contexts = db.execute("SELECT object_type,raw_id FROM bindings WHERE object_type LIKE 'context_%'").fetchall()
                    assert contexts and all(len(raw) == 64 and 'synthetic' not in raw for _, raw in contexts)
                    modes = [json.loads(row[0]).get('mode') for row in db.execute('SELECT admission_json FROM attempts')]
                    assert modes.count('compact') == 2 and all(mode in ('generation', 'compact') for mode in modes)
                print('PASS: encrypted reasoning and canonical compact windows continue; forged context rejected; namespaces/custom tools; typed context fingerprints only')
            finally:
                stop(process)
            for changed in ({'principal': 'synthetic-other-principal'}, {'identity': 'synthetic-other-account'}):
                configuration.write_text(json.dumps({**profile, **changed}))
                process, ports = start(binary, configuration, root)
                try:
                    count = provider.calls
                    assert connect(ports['data'], 'POST', '/v1/responses', continuation)[0] == 400
                    assert provider.calls == count
                finally:
                    stop(process)
            for file in (root / 'state').glob('core.sqlite*'):
                data = file.read_bytes()
                assert b'synthetic-reasoning-cipher' not in data and b'synthetic-compact-cipher' not in data
            print('PASS: cross-principal and changed-identity contexts fail before dispatch; core DB/WAL contains no opaque payload')
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=3)


if __name__ == '__main__':
    main()
