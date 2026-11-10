#!/usr/bin/env python3
"""Actual fixed-version client + actual trial serializer; isolated, synthetic, loopback only."""
import argparse
from contextlib import closing, contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
import re
from queue import Empty, Queue
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
from trial_provider import Handler, Server, TEXT, response_events
from verify_protocol import TOKEN, start, stop

MODEL='gpt-6.1-sol'
LITE_KEY='ws_request_header_x_openai_internal_codex_responses_lite'


def declarations(document):
    values=list(document.get('tools',[]))
    for item in document.get('input',[]):
        if item.get('type')=='additional_tools':
            assert item.get('role')=='developer' and 'id' not in item
            values+=item['tools']
    result=[]
    for tool in values:
        if tool['type']=='namespace':
            result.extend((tool['name'],child) for child in tool['tools'])
        else:result.append((None,tool))
    return result


class ObservedTrial(Handler):
    def events(self,document):
        assert document['model']==MODEL
        assert self.server.sequence<24, 'Unexpected repeated client execution'
        items=document.get('input',[])
        available=declarations(document)
        if 'tools' in document or any(i.get('type')=='additional_tools' for i in items):
            self.available=available
        elif document.get('previous_response_id')==getattr(self,'previous',None):
            available=getattr(self,'available',[])
        self.current_available=available
        lite=any(i.get('type')=='additional_tools' for i in items)
        if self.command=='POST' and lite:
            assert self.headers.get('x-openai-internal-codex-responses-lite')=='true'
        if self.command=='GET' and lite:
            assert document.get('client_metadata',{}).get(LITE_KEY)=='true'
        with self.server.guard:
            self.server.observed.append(dict(lite=lite,topTools='tools' in document,
                wire=self.command,
                warmup=document.get('generate') is False,
                compaction=any(i.get('type')=='compaction_trigger' for i in items),
                result=any(i.get('type')=='function_call_output' for i in items),
                context=any(i.get('type')=='compaction' for i in items),
                previous=document.get('previous_response_id')))
        events=super().events(document)
        self.previous=events[-1]['response']['id']
        return events


def fallback_prompt(index):
    return f'synthetic-fallback-turn-{index}: reply with text only.'


def fallback_reply(index):
    return f'{TEXT} Synthetic reply {index}.'


def fallback_usage(index):
    return index + 2, index + 5


class FallbackTrial(ObservedTrial):
    def events(self, document):
        events = super().events(document)
        index = len(self.server.fallback_history)
        markers = {fallback_prompt(i) for i in range(3)} | {fallback_reply(i) for i in range(3)}
        history = []
        for item in document['input']:
            content = item.get('content')
            if not isinstance(content, list):
                continue
            for part in content:
                if part.get('text') in markers:
                    history.append((item.get('role'), part['text']))
        self.server.fallback_history.append(history)
        response = events[-1]['response']
        response['output'][0]['content'][0]['text'] = fallback_reply(index)
        input_tokens, output_tokens = fallback_usage(index)
        response['usage'].update(input_tokens=input_tokens, output_tokens=output_tokens,
                                 total_tokens=input_tokens + output_tokens)
        return response_events(response)


class ScriptedTrial(ObservedTrial):
    def events(self,document):
        events=super().events(document)
        response=events[-1]['response']
        if document.get('generate') is False:return events
        for item in document.get('input',[]):
            if item.get('type')=='function_call_output' and item.get('call_id')=='call_default_client':
                output=item.get('output','')
                if self.server.tool_name=='sleep':
                    assert re.fullmatch(r'Wall time: [0-9.]+ seconds\nSleep completed\.',output), 'Synthetic sleep did not succeed'
                else:
                    assert 'Process exited with code 0\n' in output and output.rsplit('\nOutput:\n',1)[-1]=='synthetic-tool-success', 'Synthetic command did not succeed'
                self.server.tool_success_seen=True
        if self.server.observed[-1]['compaction']:
            assert self.server.tool_success_seen, 'Compaction cannot substitute for successful tool execution'
            self.server.compactions+=1
            return events
        if not self.server.tool_sent:
            available=self.current_available
            selected=next(((ns,t) for ns,t in available if ns=='clock' and t['name']=='sleep'),None)
            if selected:
                ns,tool=selected;arguments={'duration_ms':1}
            else:
                selected=next(((ns,t) for ns,t in available if t['type']=='function' and t['name']=='exec_command'),None)
                assert selected is not None, 'Fixed client no longer exposes the verified synthetic tool'
                ns,tool=selected;arguments={'cmd':'printf synthetic-tool-success','shell':'/bin/sh','login':False,'max_output_tokens':64}
            item=dict(type='function_call',id='fc_default_client',call_id='call_default_client',name=tool['name'],arguments=json.dumps(arguments))
            if ns:item['namespace']=ns
            response={**response,'output':[item]}
            self.server.tool_sent=True
            self.server.tool_name=tool['name']
        else:
            assert self.server.tool_success_seen, 'Successful tool result was not consumed'
            assert self.server.observed[-1]['result'] or self.server.observed[-1]['context'] or document.get('previous_response_id'), 'Tool/context continuation missing'
        # Uses the exact trial fixture terminal and event serializer, not verify_client.Provider.
        return response_events(response)


@contextmanager
def fallback_edge(port, prefix, enabled):
    if not enabled:
        yield port, None
        return
    wire = []
    class Edge(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            assert self.path == prefix + '/responses'
            assert self.headers.get('Upgrade', '').lower() == 'websocket'
            wire.append('WS 426')
            self.send_response(426)
            self.send_header('Content-Length', '0')
            self.end_headers()

        def do_POST(self):
            assert self.path == prefix + '/responses'
            length = int(self.headers['Content-Length'])
            assert 0 < length <= 2 * 1024 * 1024
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in {'host', 'connection', 'accept-encoding'}}
            with closing(HTTPConnection('127.0.0.1', port, timeout=10)) as target:
                target.request('POST', self.path, self.rfile.read(length), headers)
                response = target.getresponse()
                data = response.read(2 * 1024 * 1024 + 1)
                assert len(data) <= 2 * 1024 * 1024
                wire.append(f'HTTP {response.status}')
                self.send_response(response.status)
                self.send_header('Content-Type', response.getheader('Content-Type'))
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

    with ThreadingHTTPServer(('127.0.0.1', 0), Edge) as edge:
        worker = threading.Thread(target=edge.serve_forever)
        worker.start()
        try:
            yield edge.server_port, wire
        finally:
            edge.shutdown()
            worker.join(5)


def run_same_thread(codex, work, env):
    with subprocess.Popen([codex, 'app-server', '--listen', 'stdio://'], cwd=work, env=env,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True) as client:
        events = Queue()
        def receive():
            try:
                for line in client.stdout:
                    item = json.loads(line)
                    if not isinstance(item, dict):
                        raise ValueError('App-server notification is not an object')
                    events.put(item)
            except (OSError, ValueError) as error:
                events.put(error)
            finally:
                events.put(None)
        reader = threading.Thread(target=receive, daemon=True)
        reader.start()
        def send(method, params, request_id=None):
            message = dict(method=method, params=params)
            if request_id is not None:
                message['id'] = request_id
            client.stdin.write(json.dumps(message) + '\n')
            client.stdin.flush()

        replies = {}
        def until(predicate):
            deadline = time.monotonic() + 30
            while (remaining := deadline - time.monotonic()) > 0:
                try:
                    item = events.get(timeout=remaining)
                except Empty:
                    break
                if isinstance(item, Exception):
                    raise AssertionError('Cannot read App-server output') from item
                assert item is not None, 'App-server disconnected'
                if item.get('method') == 'item/completed':
                    params = item['params']
                    message = params['item']
                    if message['type'] == 'agentMessage':
                        replies.setdefault((params['threadId'], params['turnId']), []).append(message['text'])
                if predicate(item):
                    return item
            raise AssertionError('App-server did not send the expected message within 30 seconds')

        def request(method, params, request_id):
            send(method, params, request_id)
            item = until(lambda item: item.get('id') == request_id)
            assert 'result' in item, (method, item.get('error', {}).get('code'))
            return item['result']

        try:
            request('initialize', dict(clientInfo=dict(name='synthetic-test', version='1')), 1)
            send('initialized', {})
            thread = request('thread/start', dict(ephemeral=True, sandbox='read-only',
                             approvalPolicy='never'), 2)['thread']['id']
            for index in range(3):
                turn = request('turn/start', dict(threadId=thread, input=[dict(
                    type='text', text=fallback_prompt(index))]), index+3)['turn']['id']
                event = until(lambda item: item.get('method') == 'turn/completed'
                              and item['params']['turn']['id'] == turn)
                assert event['params']['threadId'] == thread
                assert event['params']['turn']['status'] == 'completed', 'Synthetic turn failed'
                assert replies.pop((thread, turn), []) == [fallback_reply(index)], 'Unexpected assistant reply'
        finally:
            client.terminate()
            try:
                client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait(timeout=5)
            reader.join(5)


def run(args,codex,transport,catalog,scenario,prefix):
    server=Server(('127.0.0.1',0),[MODEL])
    if transport == 'session-fallback':
        server.RequestHandlerClass = FallbackTrial
        server.fallback_history = []
    else:
        server.RequestHandlerClass = ObservedTrial if scenario == 'text' else ScriptedTrial
    server.observed=[];server.tool_sent=False;server.compactions=0;server.tool_name=None;server.tool_success_seen=False
    thread=threading.Thread(target=server.serve_forever);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-default-client-') as tmp:
            root=Path(tmp);home=root/'client';home.mkdir(mode=0o700);work=root/'work';work.mkdir()
            config=root/'identity.json'
            config.write_text(json.dumps(dict(principal='synthetic-principal',keyID='synthetic-key',keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-default',identity='fixture',reservedMicros=1,
                models=[dict(id=MODEL,inputMicrosPerMillion=1000000,outputMicrosPerMillion=1000000,catalog=dict(baseInstructions='Synthetic isolated connectivity and tool test. Follow only the synthetic user request.'))],
                upstreamTransport='http' if transport in ('http','fallback','session-fallback') else 'websocket',upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1')))
            config.chmod(0o600)
            process,ports=start(str(args.binary.resolve()),config,root)
            try:
                with fallback_edge(ports['data'], prefix, transport=='session-fallback') as (client_port, wire):
                    settings='[features]\napi_key_model_discovery = true\n' if catalog else ''
                    catalog_url=f'model_catalog_url = "http://127.0.0.1:{client_port}{prefix}/models"\n' if catalog else ''
                    compaction='model_auto_compact_token_limit = 1\n' if scenario=='compact' else ''
                    capabilities='\n[model_providers.synthetic.capabilities]\nremote_compaction = "v2"\n' if scenario=='compact' else ''
                    (home/'config.toml').write_text(f'''model_provider = "synthetic"
model = "{MODEL}"
web_search = "disabled"
{compaction}{settings}
[model_providers.synthetic]
name = "openai"
base_url = "http://127.0.0.1:{client_port}{prefix}"
{catalog_url}wire_api = "responses"
env_key = "SYNTHETIC_CLIENT_KEY"
requires_openai_auth = false
supports_websockets = {'true' if transport in ('native','fallback','session-fallback') else 'false'}
stream_max_retries = 0
request_max_retries = 0
{capabilities}
[analytics]
enabled = false
[feedback]
enabled = false
''')
                    env={'PATH':os.defpath,'CODEX_HOME':str(home),'SYNTHETIC_CLIENT_KEY':TOKEN,'OTEL_SDK_DISABLED':'true'}
                    if wire is not None:
                        run_same_thread(codex, work, env)
                        assert wire[:-3] in (['WS 426'], ['WS 426', 'WS 426']), wire
                        assert wire[-3:] == ['HTTP 200'] * 3, wire
                        turns = 3
                    else:
                        turns=3 if scenario=='text' else 1
                        thread_id=None
                        for index in range(turns):
                            prompt='Return the synthetic connectivity sentence. Do not use tools.' if scenario=='text' else 'Use clock.sleep once for 1 millisecond if available, otherwise exec_command once to print synthetic-tool-success, then return the synthetic connectivity sentence.'
                            command=[codex,'exec','--skip-git-repo-check','--json','--sandbox','read-only']
                            if thread_id:command+=['resume',thread_id]
                            result=subprocess.run(command+[prompt],cwd=work,env=env,capture_output=True,timeout=45)
                            events=[]
                            for line in result.stdout.splitlines():
                                try:events.append(json.loads(line))
                                except ValueError:pass
                            kinds=[e.get('type') for e in events]
                            errors=[e for e in events if e.get('type') in ('error','turn.failed')]
                            assert result.returncode==0 and not errors and 'turn.completed' in kinds, {'transport':transport,'catalog':catalog,'scenario':scenario,'turn':index,'exit':result.returncode,'events':kinds,'upstreamCalls':server.sequence}
                            assert TEXT.encode() in result.stdout, 'Actual trial response was not consumed'
                            if not thread_id:thread_id=next(e['thread_id'] for e in events if e.get('type')=='thread.started')
                    observed=list(server.observed)
                    generated=[r for r in observed if not r['warmup'] and not r['compaction']]
                    assert len(generated)==(3 if scenario=='text' else 2), {'reason':'Repeated or skipped generation','observed':observed}
                    assert all(r['wire']==('POST' if transport in ('http','fallback','session-fallback') else 'GET') for r in observed), 'Unexpected transport fallback'
                    assert sum(r['warmup'] for r in observed)==(turns if transport=='native' else 0), 'Native prewarm was skipped or repeated'
                    if wire is not None:
                        history = []
                        for index, observed_history in enumerate(server.fallback_history):
                            history.append(('user', fallback_prompt(index)))
                            assert observed_history == history, 'HTTP continuation changed ordered conversation history'
                            history.append(('assistant', fallback_reply(index)))
                    if not catalog and args.require_lite:assert any(r['lite'] for r in observed), 'Default Lite path was not exercised'
                    if catalog:assert any(r['topTools'] for r in observed), 'Explicit catalog path was not exercised'
                    if scenario!='text':assert server.tool_sent and server.tool_success_seen, 'Client did not return a successful synthetic tool result'
                    if scenario=='compact':assert server.compactions==1 and any(r['context'] for r in generated), 'Compaction/follow-up not consumed'
            finally:stop(process)
            with sqlite3.connect(root/'state/core.sqlite') as db:
                rows=db.execute('SELECT state,usage_json,admission_json FROM attempts ORDER BY rowid').fetchall()
            assert len(rows)==server.sequence and all(r[0]=='settled' for r in rows), 'Attempt accounting differs from actual upstream calls'
            usage = [(item['inputTokens'], item['outputTokens']) for item in (json.loads(row[1]) for row in rows)]
            expected = ([fallback_usage(i) for i in range(3)] if wire is not None else
                        [(0, 0) if item['warmup'] else (1, 1) for item in observed])
            assert usage == expected, 'Usage evidence differs by attempt'
            print(json.dumps(dict(transport=transport,catalog='explicit' if catalog else 'default',scenario=scenario,prefix=prefix,userTurns=turns,generations=len(generated),warmups=sum(r['warmup'] for r in observed),compactions=server.compactions,liteRequests=sum(r['lite'] for r in observed),upstreamCalls=server.sequence,settled=len(rows),tool=server.tool_name,edge=wire)),flush=True)
    finally:
        server.interrupt();server.server_close();thread.join(5)
    assert not thread.is_alive() and not server.sockets


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--codex',required=True);parser.add_argument('--expected-version',required=True)
    parser.add_argument('--require-lite',action='store_true')
    parser.add_argument('--transport',choices=['http','bridge','native','fallback','session-fallback'])
    parser.add_argument('--scenario',choices=['text','tools','compact'])
    parser.add_argument('--catalog',choices=['default','explicit'])
    args=parser.parse_args();codex=shutil.which(args.codex)
    assert codex, 'An explicit fixed-version client is required; never silently skip'
    version=subprocess.check_output([codex,'--version'],text=True,timeout=10).strip().split()[-1]
    assert version==args.expected_version, 'Client version differs from the acceptance version'
    print(json.dumps(dict(clientVersion=version,syntheticOnly=True)),flush=True)
    if args.transport == 'session-fallback':
        assert args.scenario == 'text' and args.catalog == 'default', 'Use --scenario text --catalog default for same-thread fallback'
    for transport in ([args.transport] if args.transport else ['http','bridge','native']):
        for catalog in ([args.catalog=='explicit'] if args.catalog else [False,True]):
            for scenario in ([args.scenario] if args.scenario else ['text','tools','compact']):
                run(args,codex,transport,catalog,scenario,'/v1' if catalog else '/backend-api/codex')


if __name__=='__main__':main()
