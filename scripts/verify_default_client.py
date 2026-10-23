#!/usr/bin/env python3
"""Actual fixed-version client + actual trial serializer; isolated, synthetic, loopback only."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
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


def run(args,codex,transport,catalog,scenario,prefix):
    server=Server(('127.0.0.1',0),[MODEL])
    server.RequestHandlerClass=ObservedTrial if scenario=='text' else ScriptedTrial
    server.observed=[];server.tool_sent=False;server.compactions=0;server.tool_name=None;server.tool_success_seen=False
    thread=threading.Thread(target=server.serve_forever);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-default-client-') as tmp:
            root=Path(tmp);home=root/'client';home.mkdir(mode=0o700);work=root/'work';work.mkdir()
            config=root/'identity.json'
            config.write_text(json.dumps(dict(principal='synthetic-principal',keyID='synthetic-key',keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-default',identity='fixture',reservedMicros=1,
                models=[dict(id=MODEL,inputMicrosPerMillion=1000000,outputMicrosPerMillion=1000000,catalog=dict(baseInstructions='Synthetic isolated connectivity and tool test. Follow only the synthetic user request.'))],
                upstreamTransport='http' if transport=='http' else 'websocket',upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1')))
            config.chmod(0o600)
            process,ports=start(str(args.binary.resolve()),config,root)
            try:
                settings='[features]\napi_key_model_discovery = true\n' if catalog else ''
                catalog_url=f'model_catalog_url = "http://127.0.0.1:{ports["data"]}{prefix}/models"\n' if catalog else ''
                compaction='model_auto_compact_token_limit = 1\n' if scenario=='compact' else ''
                capabilities='\n[model_providers.synthetic.capabilities]\nremote_compaction = "v2"\n' if scenario=='compact' else ''
                (home/'config.toml').write_text(f'''model_provider = "synthetic"
model = "{MODEL}"
web_search = "disabled"
{compaction}{settings}
[model_providers.synthetic]
name = "openai"
base_url = "http://127.0.0.1:{ports['data']}{prefix}"
{catalog_url}wire_api = "responses"
env_key = "SYNTHETIC_CLIENT_KEY"
requires_openai_auth = false
supports_websockets = {'true' if transport=='native' else 'false'}
stream_max_retries = 0
request_max_retries = 0
{capabilities}
[analytics]
enabled = false
[feedback]
enabled = false
''')
                env={'PATH':os.defpath,'CODEX_HOME':str(home),'SYNTHETIC_CLIENT_KEY':TOKEN,'OTEL_SDK_DISABLED':'true'}
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
                assert all(r['wire']==('POST' if transport=='http' else 'GET') for r in observed), 'Unexpected transport fallback'
                assert sum(r['warmup'] for r in observed)==(turns if transport=='native' else 0), 'Native prewarm was skipped or repeated'
                if not catalog and args.require_lite:assert any(r['lite'] for r in observed), 'Default Lite path was not exercised'
                if catalog:assert any(r['topTools'] for r in observed), 'Explicit catalog path was not exercised'
                if scenario!='text':assert server.tool_sent and server.tool_success_seen, 'Client did not return a successful synthetic tool result'
                if scenario=='compact':assert server.compactions==1 and any(r['context'] for r in generated), 'Compaction/follow-up not consumed'
            finally:stop(process)
            with sqlite3.connect(root/'state/core.sqlite') as db:
                rows=db.execute('SELECT state,usage_json,admission_json FROM attempts ORDER BY rowid').fetchall()
            assert len(rows)==server.sequence and all(r[0]=='settled' for r in rows), 'Attempt accounting differs from actual upstream calls'
            assert sum(json.loads(r[1])['inputTokens'] for r in rows)==sum(not r['warmup'] for r in observed)
            assert sum(json.loads(r[1])['outputTokens'] for r in rows)==sum(not r['warmup'] for r in observed)
            print(json.dumps(dict(transport=transport,catalog='explicit' if catalog else 'default',scenario=scenario,prefix=prefix,userTurns=turns,generations=len(generated),warmups=sum(r['warmup'] for r in observed),compactions=server.compactions,liteRequests=sum(r['lite'] for r in observed),upstreamCalls=server.sequence,settled=len(rows),tool=server.tool_name)),flush=True)
    finally:
        server.interrupt();server.server_close();thread.join(5)
    assert not thread.is_alive() and not server.sockets


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--codex',required=True);parser.add_argument('--expected-version',required=True)
    parser.add_argument('--require-lite',action='store_true')
    parser.add_argument('--transport',choices=['http','bridge','native'])
    parser.add_argument('--scenario',choices=['text','tools','compact'])
    parser.add_argument('--catalog',choices=['default','explicit'])
    args=parser.parse_args();codex=shutil.which(args.codex)
    assert codex, 'An explicit fixed-version client is required; never silently skip'
    version=subprocess.check_output([codex,'--version'],text=True,timeout=10).strip().split()[-1]
    assert version==args.expected_version, 'Client version differs from the acceptance version'
    print(json.dumps(dict(clientVersion=version,syntheticOnly=True)),flush=True)
    for transport in ([args.transport] if args.transport else ['http','bridge','native']):
        for catalog in ([args.catalog=='explicit'] if args.catalog else [False,True]):
            for scenario in ([args.scenario] if args.scenario else ['text','tools','compact']):
                run(args,codex,transport,catalog,scenario,'/v1' if catalog else '/backend-api/codex')


if __name__=='__main__':main()
