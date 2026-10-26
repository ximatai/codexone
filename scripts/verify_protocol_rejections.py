#!/usr/bin/env python3
"""Actual pre-admission HTTP/WS rejection, bounded diagnostics and no-payload logging."""
import argparse
import hashlib
import json
from pathlib import Path
import socket
import sqlite3
import tempfile
from verify_protocol import TOKEN, connect, start, stop
from verify_websocket import dial, receive, send


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    binary = str(parser.parse_args().binary.resolve())
    secret = 'synthetic-private-payload-never-log'
    with tempfile.TemporaryDirectory(prefix='codexone-rejection-') as temporary, socket.socket() as upstream:
        upstream.bind(('127.0.0.1', 0))
        upstream.listen(8)
        upstream.settimeout(0.1)
        root = Path(temporary)
        config = root / 'identity.json'
        config.write_text(json.dumps(dict(principal='synthetic-principal', keyID='synthetic-key',
            keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), namespace='synthetic-rejection',
            identity='fixture', reservedMicros=1, upstreamTransport='websocket',
            models=[dict(id='synthetic-text', inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
            upstreamBaseURL=f'http://127.0.0.1:{upstream.getsockname()[1]}/v1')))
        config.chmod(0o600)
        process, ports = start(binary, config, root)
        try:
            # Gateway-owned rejections only: provider-state references, background and permissions.
            request = dict(model='synthetic-text', input=secret, conversation=dict(id=secret))
            status, body = connect(ports['data'], 'POST', '/v1/responses', request)
            assert status == 400 and json.loads(body)['error']['code'] == 'unsupported_request'
            for document, code in [({'type': 'response.create', **request}, 'unsupported_request'),
                                   ({'type': 'response.cancel', 'private': secret}, 'unsupported_websocket_control')]:
                with dial(ports['data']) as sock:
                    send(sock, document, masked=True)
                    opcode, data = receive(sock)
                    event = json.loads(data)
                    assert opcode == 1 and event['type'] == 'error' and event['error']['code'] == code
                    assert 'stream_id' not in event and secret.encode() not in data
            image = dict(type='additional_tools', role='developer', tools=[dict(type='image_generation')])
            for extra, code in [(dict(background=True), 'unsupported_background'), (dict(generate=False), 'unsupported_request'),
                                (dict(prompt=dict(id=secret)), 'unsupported_request'),
                                (dict(input=[image]), 'unsupported_tools'), (dict(store='false'), 'invalid_request')]:
                status, body = connect(ports['data'], 'POST', '/v1/responses', {**dict(model='synthetic-text', input=secret), **extra})
                error = json.loads(body)['error']
                assert status == 400 and error['code'] == code and 'reason' not in error, (extra, body)
            for _ in range(30):
                assert connect(ports['data'], 'POST', '/backend-api/codex/responses', request)[0] == 400
            with sqlite3.connect(root / 'state/core.sqlite') as db:
                assert db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0] == 0
                assert db.execute('SELECT COUNT(*) FROM bindings').fetchone()[0] == 0
            try:
                connection, _ = upstream.accept()
                connection.close()
                raise AssertionError('Rejected request opened an upstream connection')
            except socket.timeout:
                pass
            process.terminate()
            process.wait(8)
            output = process.stdout.read()
            assert process.returncode == 0
            assert output.count(b'Protocol request rejected') == 16
            assert b'unsupported_request' in output and b'unsupported_websocket_control' in output
            assert b'reason=tools_image' in output
            for value in [secret, TOKEN, 'synthetic-header', str(config)]:
                assert value.encode() not in output
        finally:
            stop(process)
    print('PASS: first WS error frames, HTTP rejection, no upstream/intent/binding, bounded 16/minute diagnostics and no payload/header/path logging')


if __name__ == '__main__':
    main()
