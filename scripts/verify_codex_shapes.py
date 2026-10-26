#!/usr/bin/env python3
"""Codex-shaped requests and provider streams pass through every transport intact.

Shapes follow the public Codex client models (web search, tool search, structured tool output,
encrypted history, annotations, metadata and rate-limit events) instead of this gateway's own
assumptions. Provider failures must reach the client with their actionable code, never with
provider account identifiers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import threading
import time
from trial_provider import Server, response_events
from verify_protocol import TOKEN, connect, start, stop
from verify_upstream_events import states
from verify_upstream_proxy import Observed
from verify_websocket import dial, receive, send

MODEL = 'synthetic-codex'
PRIVATE_ORG = 'org-SyntheticPrivateOrg42'
TOOLS = [
    dict(type='function', name='exec_command', description='x' * 40000, strict=False,
         parameters=dict(type='object', properties=dict(cmd=dict(type='string')), required=['cmd'])),
    dict(type='custom', name='apply_patch', description='synthetic patch tool',
         format=dict(type='grammar', syntax='lark', definition='start: /.+/')),
    dict(type='web_search', external_web_access=False),
    dict(type='tool_search', execution='client', description='synthetic', parameters=dict(type='object')),
    dict(type='namespace', name='mcp__synthetic', description='synthetic server',
         tools=[dict(type='function', name='read', description='y' * 50000, parameters=dict(type='object'),
                     defer_loading=True)]),
]


def history():
    items = [dict(type='message', role='developer', content=[dict(type='input_text', text='synthetic rules')])]
    for index in range(80):
        items += [
            dict(type='message', role='user', content=[dict(type='input_text', text=f'synthetic step {index}')]),
            dict(type='reasoning', id=f'rs_{index}', summary=[dict(type='summary_text', text='s')],
                 encrypted_content=f'synthetic-cipher-{index}'),
            dict(type='function_call', id=f'fc_{index}', call_id=f'call_{index}', name='exec_command',
                 arguments='{"cmd":"true"}', encrypted_content='synthetic-call-cipher'),
            dict(type='function_call_output', call_id=f'call_{index}',
                 output=[dict(type='input_text', text='synthetic output ' + 'z' * 8000)]),
        ]
    items += [
        dict(type='web_search_call', id='ws_history', status='completed',
             action=dict(type='search', query='synthetic')),
        dict(type='local_shell_call', id='lsh_history', call_id='call_shell', status='completed',
             action=dict(type='exec', command=['true'])),
        dict(type='tool_search_call', id='ts_history', call_id='call_search', execution='client',
             arguments=dict(query='synthetic')),
        dict(type='tool_search_output', call_id='call_search', status='completed', execution='client', tools=[]),
        dict(type='message', role='assistant', phase='commentary', encrypted_content='synthetic-message-cipher',
             content=[dict(type='output_text', text='synthetic', annotations=[
                 dict(type='url_citation', url='https://example.invalid', title='t', start_index=0, end_index=1)])]),
        dict(type='message', role='user', content=[dict(type='input_text', text='synthetic final question')]),
    ]
    return items


def request(**extra):
    return {**dict(model=MODEL, input=history(), tools=TOOLS, tool_choice='auto', parallel_tool_calls=True,
                reasoning=dict(effort='high', summary='auto'), store=False, stream=True,
                include=['reasoning.encrypted_content'], prompt_cache_key='synthetic-thread',
                text=dict(verbosity='low'), client_metadata=dict(synthetic='true'),
                service_tier='priority'), **extra}


class Codex(Observed):
    def events(self, document):
        scenario = self.server.scenario
        with self.server.guard:
            self.server.sequence += 1
            self.server.documents.append(document)
            index = f'{self.server.epoch}_{self.server.sequence}'
        error = dict(code='context_length_exceeded',
                     message=f'Input exceeds the context window for {PRIVATE_ORG}; contact a@example.com')
        if scenario == 'ws-error':
            return [dict(type='error', status=429, error=dict(
                type='usage_limit_reached', message=f'Limit reached for {PRIVATE_ORG}', resets_in_seconds=60))]
        output = [
            dict(type='reasoning', id=f'rs_{index}', summary=[dict(type='summary_text', text='s')],
                 encrypted_content=f'synthetic-new-cipher-{index}', synthetic_future_member=True),
            dict(type='web_search_call', id=f'ws_{index}', status='completed',
                 action=dict(type='search', query='synthetic', sources=[dict(type='url', url='https://example.invalid')])),
            dict(type='message', id=f'msg_{index}', role='assistant', status='completed', phase='final_answer',
                 content=[dict(type='output_text', text='synthetic answer', logprobs=[], annotations=[
                     dict(type='url_citation', url='https://example.invalid', title='t', start_index=0, end_index=9)])]),
            dict(type='function_call', id=f'fc_{index}', call_id=f'call_new_{index}', name='undeclared_tool',
                 namespace='mcp__other', arguments='{}', status='completed'),
        ]
        response = dict(id=f'resp_{index}', object='response', model=MODEL, status='completed', output=output,
                        instructions=[dict(type='message', role='developer', content=[])], tools=document.get('tools'),
                        tool_choice='auto', reasoning=dict(effort='high', summary='detailed'), store=False,
                        background=False, metadata={}, user=None, safety_identifier='synthetic', prompt_cache_retention=None,
                        usage=dict(input_tokens=1000, output_tokens=20, total_tokens=1020,
                                   input_tokens_details=dict(cached_tokens=900, synthetic_counter='x'),
                                   output_tokens_details=dict(reasoning_tokens=5), synthetic_cost=dict(credits='1')))
        if scenario == 'failed':
            response.update(status='failed', output=[], error=error)
        events = response_events(response)
        if scenario == 'failed':
            events = [events[0], dict(type='response.failed', response=response)]
        else:
            web = next(i for i, e in enumerate(events) if e.get('type') == 'response.output_item.added'
                       and e['item']['type'] == 'web_search_call')
            events[web + 1:web + 1] = [
                dict(type='response.web_search_call.in_progress', item_id=f'ws_{index}', output_index=1),
                dict(type='response.web_search_call.searching', item_id=f'ws_{index}', output_index=1),
                dict(type='response.web_search_call.completed', item_id=f'ws_{index}', output_index=1)]
            text = next(i for i, e in enumerate(events) if e.get('type') == 'response.output_text.done')
            events.insert(text + 1, dict(type='response.output_text.annotation.added', item_id=f'msg_{index}',
                                         output_index=2, content_index=0, annotation_index=0,
                                         annotation=dict(type='url_citation', url='https://example.invalid')))
        if self.command == 'GET' or document.get('stream'):
            events.insert(0, dict(type='response.metadata', headers={'x-codex-turn-state': 'synthetic'}))
            events.append(dict(type='codex.rate_limits', rate_limits=dict(primary=dict(used_percent=1))))
        return events

    def do_POST(self):
        if self.server.scenario == 'http429':
            self.accept_upstream_credential()
            self.close_connection = True
            length = int(self.headers['Content-Length'])
            self.rfile.read(length)
            with self.server.guard:
                self.server.sequence += 1
            body = json.dumps(dict(error=dict(type='usage_limit_reached', plan_type='plus', resets_in_seconds=60,
                                              message=f'You have hit your usage limit ({PRIVATE_ORG}).'))).encode()
            self.send_response(429)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_POST()


def sse(body):
    return [json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: ') and line[6:] != b'[DONE]']


def native_turn(sock, value):
    send(sock, {'type': 'response.create', **value}, masked=True, maximum_bytes=8388608)
    events = []
    while True:
        opcode, data = receive(sock)
        assert opcode == 1
        events.append(json.loads(data))
        if events[-1]['type'] in ('response.completed', 'response.failed', 'error'):
            return events
        assert len(events) < 64


def expect_success(events):
    types = [e.get('type') for e in events]
    for expected in ['response.metadata', 'response.web_search_call.searching', 'response.output_text.annotation.added',
                     'codex.rate_limits'] if 'codex.rate_limits' in types else ['response.metadata',
                     'response.web_search_call.searching', 'response.output_text.annotation.added']:
        assert expected in types, (expected, types)
    done = [e for e in events if e.get('type') == 'response.completed']
    assert len(done) == 1
    output = done[0]['response']['output']
    assert [item['type'] for item in output] == ['reasoning', 'web_search_call', 'message', 'function_call']
    assert output[0]['synthetic_future_member'] is True
    assert output[2]['content'][0]['annotations'][0]['type'] == 'url_citation'
    assert done[0]['response']['usage']['input_tokens_details'] == dict(cached_tokens=900)
    return done[0]['response']


def check_forwarded(provider, sent):
    received = provider.documents[-1]
    assert received['tools'] == sent['tools']
    assert len(received['input']) == len(sent['input'])
    assert [i.get('type') for i in received['input']] == [i.get('type') for i in sent['input']]
    for key in ['include', 'prompt_cache_key', 'text', 'reasoning', 'service_tier', 'tool_choice']:
        assert received[key] == sent[key], key


def wait_states(root, count, kind):
    deadline = time.monotonic() + 5
    while not (len(states(root)) == count and all(s == 'settled' and k == kind for s, k, _ in states(root))):
        assert time.monotonic() < deadline, states(root)
        time.sleep(.02)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    binary = str(parser.parse_args().binary.resolve())
    provider = Server(('127.0.0.1', 0), [MODEL])
    provider.RequestHandlerClass = Codex
    provider.documents = []
    thread = threading.Thread(target=provider.serve_forever)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-codex-shapes-') as temporary:
            owner = Path(temporary)
            for transport in ['http', 'websocket']:
                for scenario in ['ok', 'failed', 'http429' if transport == 'http' else 'ws-error']:
                    provider.scenario = scenario
                    root = owner / (transport + '-' + scenario)
                    root.mkdir(mode=0o700)
                    secret = root / 'access'
                    secret.write_text('synthetic-private-upstream-token-never-log')
                    secret.chmod(0o600)
                    config = root / 'identity.json'
                    config.write_text(json.dumps(dict(
                        principal='synthetic-codex', keyID='synthetic-key',
                        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), namespace='synthetic-codex',
                        identity='synthetic-identity',
                        models=[dict(id=MODEL, inputMicrosPerMillion=0, outputMicrosPerMillion=0)], reservedMicros=1,
                        upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1', upstreamTransport=transport,
                        upstreamTokenFile=str(secret))))
                    config.chmod(0o600)
                    process, ports = start(binary, config, root)
                    try:
                        sent = request()
                        assert len(json.dumps(sent)) > 524288, 'Fixture must exceed the former text limit'
                        status, body = connect(ports['data'], 'POST', '/v1/responses', sent)
                        assert PRIVATE_ORG.encode() not in body and b'a@example.com' not in body
                        if scenario == 'ok':
                            assert status == 200, body[:300]
                            response = expect_success(sse(body))
                            check_forwarded(provider, sent)
                            # Continuation over the full window, including the new opaque history.
                            follow = request()
                            follow['input'] += response['output'] + [
                                dict(type='function_call_output', call_id=response['output'][3]['call_id'],
                                     output='synthetic result')]
                            status, body = connect(ports['data'], 'POST', '/v1/responses', follow)
                            assert status == 200 and len([e for e in sse(body) if e.get('type') == 'response.completed']) == 1
                            status, body = connect(ports['data'], 'POST', '/v1/responses', request(stream=False))
                            assert status == 200 and json.loads(body)['output'][1]['type'] == 'web_search_call', body[:400]
                            count = 3
                            if transport == 'websocket':
                                with dial(ports['data']) as client:
                                    first = native_turn(client, request())
                                    assert first[0]['type'] == 'response.metadata'
                                    response = expect_success(first)
                                    second = native_turn(client, dict(model=MODEL, previous_response_id=response['id'],
                                                                      input=[dict(type='function_call_output',
                                                                                  call_id=response['output'][3]['call_id'],
                                                                                  output='synthetic result')]))
                                    assert second[-1]['type'] == 'response.completed'
                                count += 2
                            wait_states(root, count, 'succeeded')
                        elif scenario == 'failed':
                            events = sse(body)
                            failed = [e for e in events if e.get('type') == 'response.failed']
                            assert status == 200 and len(failed) == 1, body[:300]
                            error = failed[0]['response']['error']
                            assert error['code'] == 'context_length_exceeded' and '[redacted]' in error['message']
                            wait_states(root, 1, 'failed')
                        elif scenario == 'http429':
                            error = json.loads(body)['error']
                            assert status == 429 and error['type'] == 'usage_limit_reached', body
                            assert error['resets_in_seconds'] == 60 and error['plan_type'] == 'plus'
                            assert error['request_id'] and '[redacted]' in error['message']
                        else:
                            error = json.loads(body)['error']
                            assert status == 429 and error['type'] == 'usage_limit_reached', body
                            with dial(ports['data']) as client:
                                provider.scenario = 'ok'
                                assert native_turn(client, request())[-1]['type'] == 'response.completed'
                                provider.scenario = 'ws-error'
                                events = native_turn(client, request())
                                assert events[-1]['type'] == 'error' and events[-1]['status'] == 429
                                assert events[-1]['error']['type'] == 'usage_limit_reached'
                                assert PRIVATE_ORG not in json.dumps(events)
                                # A later turn's provider error leaves the pinned connection usable.
                                provider.scenario = 'ok'
                                assert native_turn(client, request())[-1]['type'] == 'response.completed'
                        process.terminate()
                        process.wait(10)
                        logs = process.stdout.read()
                        assert PRIVATE_ORG.encode() not in logs and b'synthetic-private-upstream-token-never-log' not in logs
                        assert b'synthetic answer' not in logs and b'synthetic-cipher' not in logs
                    finally:
                        stop(process)
                print(f'PASS: {transport} Codex-shaped tools/history/events/annotations pass through; failed, '
                      'rate-limit and error events reach the client with sanitized actionable codes', flush=True)
    finally:
        provider.interrupt()
        provider.server_close()
        thread.join(5)


if __name__ == '__main__':
    main()
