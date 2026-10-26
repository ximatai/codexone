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
                {k: document[k] for k in ['text', 'tool_choice', 'parallel_tool_calls', 'stream_options'] if k in document}))
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
             ({'effort': 'high'}, {'effort': 'high'}, {'text': {'verbosity': 'high'}, 'tool_choice': 'auto', 'parallel_tool_calls': False}),
             *[({'effort': 'high', 'context': context}, {'effort': 'high', 'context': context}, {'stream_options': {'reasoning_summary_delivery': 'sequential_cutoff'}}) for context in ['auto', 'current_turn', 'all_turns']],
             ({'context': None}, {}, {'stream_options': {'include_usage': True, 'reasoning_summary_delivery': 'sequential_cutoff'}})]
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
                            controls = {k: v for k, v in extra.items() if k in ['text', 'tool_choice', 'parallel_tool_calls', 'stream_options'] and v is not None}
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
                        # Values the gateway does not own are the provider's to judge: forwarded, never rejected.
                        for future in [dict(reasoning={'effort': 'xhigh', 'context': 'future'}), dict(text={'verbosity': 'max'}),
                                       dict(stream_options={'future_delivery': 'synthetic'}), dict(reasoning={'summary': None, 'private': None})]:
                            before = server.sequence
                            status, body = connect(ports['data'], 'POST', prefix + '/responses', dict(model='synthetic-text', input='Synthetic future control', **future))
                            assert status == 200 and server.sequence == before + 1
                            observed = server.observed[-1]
                            if 'reasoning' in future: assert observed[0] == {k: v for k, v in future['reasoning'].items() if v is not None}
                            else: assert all(observed[3][k] == v for k, v in future.items())
                finally:
                    stop(process)
    finally:
        server.interrupt()
        server.server_close()
        thread.join(3)
    assert not thread.is_alive() and not server.sockets
    print('PASS: known nullable reasoning/text/tool controls normalize across both prefixes, HTTP JSON/SSE, bridge/native WS/warmup; explicit tools omission preserved; future members forwarded for the provider to judge')


if __name__ == '__main__':
    main()
