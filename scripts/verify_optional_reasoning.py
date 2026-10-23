#!/usr/bin/env python3
"""Real HTTP/SSE, bridge/native WS and warmup: nullable reasoning never reaches upstream."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
from trial_provider import Handler, Server, TEXT
from verify_protocol import TOKEN, connect, start, stop
from verify_websocket import dial, turn


class RecordingHandler(Handler):
    def events(self, document):
        with self.server.guard:
            self.server.observed.append((document.get('reasoning'), 'tools' in document, document.get('tools'),
                {k: document[k] for k in ['text', 'tool_choice', 'parallel_tool_calls'] if k in document}))
        return super().events(document)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    binary = str(parser.parse_args().binary.resolve())
    server = Server(('127.0.0.1', 0), ['synthetic-text'])
    server.RequestHandlerClass = RecordingHandler
    server.observed = []
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    cases = [({'effort': None, 'summary': None}, {}, {}),
             ({'effort': 'high', 'summary': None}, {'effort': 'high'}, {'tools': []}),
             ({'effort': None, 'summary': 'auto'}, {'summary': 'auto'}, {}),
             ({'effort': 'ultra', 'summary': 'none'}, {'effort': 'ultra', 'summary': 'none'}, {'tools': []}),
             ({'summary': None}, {}, {'text': {'verbosity': None, 'format': None}, 'tool_choice': None, 'parallel_tool_calls': None}),
             ({'effort': 'high'}, {'effort': 'high'}, {'text': {'verbosity': 'high'}, 'tool_choice': 'auto', 'parallel_tool_calls': False})]
    try:
        for transport in ['http', 'websocket']:
            with tempfile.TemporaryDirectory(prefix='codexone-reasoning-') as temporary:
                root = Path(temporary)
                config = root / 'identity.json'
                config.write_text(json.dumps(dict(principal='synthetic-principal', keyID='synthetic-key',
                    keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), namespace='synthetic-reasoning',
                    identity='fixture', reservedMicros=1, upstreamTransport=transport,
                    models=[dict(id='synthetic-text', inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
                    upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1')))
                config.chmod(0o600)
                process, ports = start(binary, config, root)
                try:
                    for prefix in ['/v1', '/backend-api/codex']:
                        for reasoning, expected, extra in cases:
                            request = dict(model='synthetic-text', input='Synthetic nullable reasoning check',
                                           reasoning=reasoning, **extra)
                            controls = {k: v for k, v in extra.items() if k in ['text', 'tool_choice', 'parallel_tool_calls'] and v is not None}
                            if 'text' in controls: controls['text'] = {k: v for k, v in controls['text'].items() if v is not None}
                            expected_wire = (expected, 'tools' in extra, extra.get('tools'), controls)
                            for stream in [False, True]:
                                status, body = connect(ports['data'], 'POST', prefix + '/responses', {**request, 'stream': stream})
                                assert status == 200 and TEXT.encode() in body
                                assert server.observed[-1] == expected_wire
                            if transport == 'websocket':
                                with dial(ports['data'], path=prefix + '/responses') as sock:
                                    for warmup in [True, False]:
                                        events = turn(sock, {**request, **({'generate': False} if warmup else {})})
                                        assert events[-1]['type'] == 'response.completed'
                                        assert server.observed[-1] == expected_wire
                                        if warmup: assert events[-1]['response']['output'] == []
                        before = server.sequence
                        with sqlite3.connect(root / 'state/core.sqlite') as db:
                            attempts = db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0]
                        for invalid in [dict(reasoning={'effort': False}), dict(reasoning={'summary': []}), dict(reasoning={'summary': None, 'private': None}), dict(text={'verbosity': False}), dict(text={'format': False}), dict(tool_choice=False), dict(parallel_tool_calls='false')]:
                            request = dict(model='synthetic-text', input='Synthetic rejection check', **invalid)
                            code = 'unsupported_reasoning' if 'reasoning' in invalid else 'unsupported_text' if 'text' in invalid else 'unsupported_tools' if 'tool_choice' in invalid else 'invalid_request'
                            status, body = connect(ports['data'], 'POST', prefix + '/responses', request)
                            assert status == 400 and json.loads(body)['error']['code'] == code
                            if transport == 'websocket':
                                with dial(ports['data'], path=prefix + '/responses') as sock:
                                    assert turn(sock, request)[-1]['error']['code'] == code
                        assert server.sequence == before
                        with sqlite3.connect(root / 'state/core.sqlite') as db:
                            assert db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0] == attempts
                            assert db.execute("SELECT COUNT(*) FROM attempts WHERE state!='settled'").fetchone()[0] == 0
                finally:
                    stop(process)
    finally:
        server.interrupt()
        server.server_close()
        thread.join(3)
    assert not thread.is_alive() and not server.sockets
    print('PASS: known nullable reasoning/text/tool controls normalize across both prefixes, HTTP JSON/SSE, bridge/native WS/warmup; explicit tools omission preserved; wrong/unknown fields never dispatch')


if __name__ == '__main__':
    main()
