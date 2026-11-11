#!/usr/bin/env python3
"""Fixed Codex CLI continuity regressions with a loopback provider and a synthetic key."""
import argparse
from contextlib import closing, contextmanager, nullcontext
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import select
import socket
import sqlite3
import subprocess
import tempfile
import threading

from trial_provider import Server, TEXT, response_events
from verify_default_client import MODEL, ObservedTrial, app_server, declarations, finished_turn, start_turn
from verify_protocol import TOKEN, start, stop
from verify_websocket import exact, receive, send


DEVELOPER = 'Synthetic continuity developer marker'
FIRST = 'Synthetic first request. Reply with text only.'
NEXT = 'Synthetic steering follow-up. Reply with text only.'
NEXT_REPLY = 'Synthetic follow-up response received.'


class ContinuityTrial(ObservedTrial):
    def events(self, document):
        events = super().events(document)
        with self.server.guard:
            assert len(self.server.creates) < 8
            self.server.creates.append((self.connection, document, events[-1]['response']['id']))
            generated = sum(d.get('generate') is not False for _, d, _ in self.server.creates)
        if document.get('generate') is False:
            yield from events
        elif self.server.scenario == 'late-interrupt' and generated == 2:
            response = events[-1]['response']
            response['output'][0]['content'][0]['text'] = NEXT_REPLY
            yield from response_events(response)
        elif generated != 1:
            yield from events
        elif self.server.scenario == 'prewarm-drop':
            self.connection.shutdown(socket.SHUT_RDWR)
        else:
            yield from events[:-1]
            assert self.server.release_terminal.wait(10), 'Client did not send an interrupt'
            yield events[-1]


@contextmanager
def interrupt_edge(gateway_port, provider):
    """Delay the real client's interrupt until the gateway has forwarded the terminal."""
    trace = []

    class Edge(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def do_GET(self):
            self.close_connection = True
            assert self.path == '/backend-api/codex/responses'
            self.connection.settimeout(10)
            with closing(socket.create_connection(('127.0.0.1', gateway_port), timeout=10)) as gateway:
                request = self.raw_requestline + b''.join(
                    f'{name}: {value}\r\n'.encode('ascii')
                    for name, value in self.headers.raw_items()
                ) + b'\r\n'
                gateway.sendall(request)
                header = bytearray()
                while not header.endswith(b'\r\n\r\n'):
                    assert len(header) < 8192
                    header.extend(exact(gateway, 1))
                assert header.startswith(b'HTTP/1.1 101 '), bytes(header).splitlines()[0]
                self.connection.sendall(header)
                self.relay(gateway)

        def relay(self, gateway):
            pending = None
            terminal = None
            while True:
                ready, _, _ = select.select([self.connection, gateway], [], [], 10)
                assert ready, 'WebSocket fixture relay timed out'
                for source in ready:
                    from_client = source is self.connection
                    target = gateway if from_client else self.connection
                    try:
                        opcode, payload = receive(source, masked=from_client)
                    except (EOFError, ConnectionResetError):
                        return
                    event = json.loads(payload) if opcode == 1 else {}
                    if from_client and event.get('type') == 'response.interrupt':
                        assert pending is None and terminal is None, 'Unexpected duplicate interrupt'
                        pending = (payload, event['response_id'])
                        trace.append('client_interrupt')
                        provider.release_terminal.set()
                        continue
                    if not from_client and pending and event.get('type') == 'response.completed':
                        assert event['response']['id'] == pending[1]
                        terminal = pending[1]
                        trace.append('old_terminal')
                        send(gateway, pending[0], masked=True)
                        pending = None
                    if not from_client and event.get('type') == 'response.interrupt.failed':
                        assert event['response_id'] == terminal
                        trace.append('late_failure')
                    send(target, payload, masked=from_client, opcode=opcode)
                    if opcode == 8:
                        return

    with ThreadingHTTPServer(('127.0.0.1', 0), Edge) as edge:
        worker = threading.Thread(target=edge.serve_forever)
        worker.start()
        try:
            yield edge.server_port, trace
        finally:
            edge.shutdown()
            worker.join(5)


def prewarm_recovery(codex, work, environment, provider):
    with app_server(codex, work, environment) as (thread, request, until, replies):
        turn = start_turn(request, thread, FIRST, 3)
        assert finished_turn(until, thread, turn) == 'completed', 'Client did not recover the turn'
        assert replies[(thread, turn)] == [TEXT]

    with provider.guard:
        creates = list(provider.creates)
    assert len(creates) == 3, f'Expected one prewarm, one drop and one retry, saw {len(creates)} creates'
    (warm_socket, warm, warm_id), (drop_socket, dropped, _), (retry_socket, retry, _) = creates
    assert warm.get('generate') is False and dropped.get('previous_response_id') == warm_id
    assert warm_socket is drop_socket and retry_socket is not drop_socket
    assert retry.get('previous_response_id') is None and retry.get('generate') is not False
    original_tools = {(ns, tool['name']): tool for document in (warm, dropped)
                      for ns, tool in declarations(document)}
    retry_tools = {(ns, tool['name']): tool for ns, tool in declarations(retry)}
    assert original_tools and all(
        retry_tools.get(key) == tool for key, tool in original_tools.items()
    ), 'Tool declarations changed on reconnect'
    assert DEVELOPER in json.dumps(retry['input']), 'Developer context lost on reconnect'
    assert FIRST in json.dumps(retry['input']), 'User input lost on reconnect'
    return ['settled', 'unknown', 'settled']


def late_interrupt(codex, work, environment, provider, trace):
    with app_server(codex, work, environment) as (thread, request, until, replies):
        turn = start_turn(request, thread, FIRST, 3)
        until(lambda item: item.get('method') == 'item/agentMessage/delta'
              and item['params']['turnId'] == turn)
        steered = request('turn/steer', dict(threadId=thread, expectedTurnId=turn,
                                             input=[dict(type='text', text=NEXT)]), 4)
        assert steered['turnId'] == turn
        assert finished_turn(until, thread, turn) == 'completed', 'Late frame affected the follow-up'
        assert replies[(thread, turn)] == [TEXT, NEXT_REPLY]
    assert trace == ['client_interrupt', 'old_terminal', 'late_failure'], trace
    with provider.guard:
        creates = list(provider.creates)
    assert len(creates) == 3 and creates[0][1].get('generate') is False
    _, (first_socket, first, _), (next_socket, followup, _) = creates
    assert next_socket is first_socket, 'Follow-up did not reuse the native socket'
    assert FIRST in json.dumps(first['input'])
    assert NEXT in json.dumps(followup['input'])
    return ['settled'] * 3


def run(args):
    provider = Server(('127.0.0.1', 0), [MODEL])
    provider.RequestHandlerClass = ContinuityTrial
    provider.scenario = args.scenario
    provider.creates = []
    provider.observed = []
    provider.release_terminal = threading.Event()
    worker = threading.Thread(target=provider.serve_forever)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-continuity-') as tmp:
            root = Path(tmp)
            home, work = root/'client', root/'work'
            home.mkdir(mode=0o700)
            work.mkdir()
            config = root/'identity.json'
            config.write_text(json.dumps(dict(
                principal='synthetic-principal', keyID='synthetic-key',
                keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), namespace='synthetic-continuity',
                identity='fixture', reservedMicros=1,
                models=[dict(id=MODEL, inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
                upstreamTransport='websocket', upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1')))
            config.chmod(0o600)
            gateway, ports = start(str(args.binary.resolve()), config, root)
            try:
                if args.scenario == 'late-interrupt':
                    edge = interrupt_edge(ports['data'], provider)
                else:
                    edge = nullcontext((ports['data'], None))
                with edge as (port, trace):
                    (home/'config.toml').write_text(f'''model_provider = "synthetic"
model = "{MODEL}"
developer_instructions = "{DEVELOPER}"
web_search = "disabled"
[model_providers.synthetic]
name = "openai"
base_url = "http://127.0.0.1:{port}/backend-api/codex"
wire_api = "responses"
env_key = "SYNTHETIC_CLIENT_KEY"
requires_openai_auth = false
supports_websockets = true
stream_max_retries = {1 if trace is None else 0}
request_max_retries = 0
[analytics]
enabled = false
[feedback]
enabled = false
''')
                    environment = dict(PATH=os.defpath, CODEX_HOME=str(home),
                                       SYNTHETIC_CLIENT_KEY=TOKEN, OTEL_SDK_DISABLED='true')
                    if trace is None:
                        expected = prewarm_recovery(args.codex, work, environment, provider)
                    else:
                        expected = late_interrupt(args.codex, work, environment, provider, trace)
            finally:
                stop(gateway)
            with sqlite3.connect(root/'state/core.sqlite') as db:
                rows = db.execute('SELECT state, usage_json FROM attempts ORDER BY rowid').fetchall()
            assert len(rows) == len(provider.creates)
            assert [state for state, _ in rows] == expected, [state for state, _ in rows]
            for (_, request, _), (state, usage_json) in zip(provider.creates, rows):
                if state == 'unknown':
                    assert usage_json is None
                else:
                    usage = json.loads(usage_json)
                    tokens = 0 if request.get('generate') is False else 1
                    assert (usage['inputTokens'], usage['outputTokens']) == (tokens, tokens)
            print(f'PASS: {args.scenario}; {len(rows)} provider creates match durable attempts')
    finally:
        provider.release_terminal.set()
        provider.interrupt()
        provider.server_close()
        worker.join(5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--codex', required=True)
    parser.add_argument('--expected-version', required=True)
    parser.add_argument('--scenario', choices=['prewarm-drop', 'late-interrupt'], required=True)
    args = parser.parse_args()
    version = subprocess.check_output([args.codex, '--version'], text=True, timeout=10).strip().split()[-1]
    assert version == args.expected_version, 'Client version differs from the acceptance version'
    run(args)


if __name__ == '__main__':
    main()
