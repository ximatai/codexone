#!/usr/bin/env python3
"""Request contracts against a capturing, credential-free socket provider."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from verify_protocol import TOKEN, start, stop
from verify_text_contract import Provider as WireProvider, FIXTURE, call, rows

class Provider(WireProvider):
    def do_GET(self):
        with self.server.guard: self.server.upgrades += 1
        return super().do_GET()

    def sequence(self, request):
        with self.server.guard:
            self.server.calls += 1
            count = self.server.calls
            self.server.received.append(request)
        return json.loads(self.server.literal.replace('resp_contract_1', f'resp_contract_{count}')
                          .replace('msg_contract_1', f'msg_contract_{count}'))

def attempt_count(root):
    with sqlite3.connect(root/'state/core.sqlite') as db:
        return db.execute('SELECT count(*) FROM attempts').fetchone()[0]

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',0),Provider);server.guard=threading.Lock();server.calls=0;server.upgrades=0
    server.received=[];server.literal=json.dumps(json.loads(FIXTURE.read_text())['events'])
    worker=threading.Thread(target=server.serve_forever);worker.start()
    unsupported=[{key:value} for key,value in [('store',True),('max_output_tokens',128),('temperature',1),
        ('top_p',.5),('truncation','disabled'),('prompt_cache_retention','24h'),('metadata',{'label':'synthetic'})]]
    total=0
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-parameters-') as temporary:
            for contract in ('responses','codex-subscription'):
                for transport in ('http','websocket'):
                    root=Path(temporary)/(contract+'-'+transport);root.mkdir(mode=0o700)
                    config=root/'identity.json';config.write_text(json.dumps(dict(principal='synthetic-contract',keyID='synthetic-key',
                        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-contract',identity='synthetic-identity',
                        models=[dict(id='synthetic-contract',inputMicrosPerMillion=0,outputMicrosPerMillion=0)],reservedMicros=1,
                        upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1',upstreamTransport=transport,upstreamContract=contract)));config.chmod(0o600)
                    process,ports=start(str(args.binary.resolve()),config,root)
                    try:
                        for route in (('json','sse') if transport=='http' else ('json','sse','native')):
                            base=dict(model='synthetic-contract',input='synthetic parameter probe',instructions='synthetic instructions',
                                      prompt_cache_key='synthetic-cache',client_metadata={'label':'synthetic'},parallel_tool_calls=True)
                            good = [dict(include=['reasoning.encrypted_content', 'output.encrypted_content']),
                                    dict(service_tier='priority'),dict(store=False),dict(temperature=None,top_p=None,max_output_tokens=None,
                                    metadata=None,truncation=None,prompt_cache_retention=None,service_tier=None)]
                            if contract=='responses':
                                good += [dict(temperature=0,top_p=0,max_output_tokens=16,service_tier='flex',truncation='disabled',prompt_cache_retention='24h'),
                                         dict(temperature=2,top_p=1,max_output_tokens=128,service_tier='fast'),dict(store=True)]
                            else: good += [dict(service_tier='auto'),dict(service_tier='default'),dict(service_tier='flex')]
                            # Values the provider judges are forwarded, including future fields.
                            good += [dict(synthetic_future_field={'enabled':True})]
                            for extra in good:
                                before=server.calls;status,events=call(ports['data'],route,{**base,**extra});total+=1
                                assert status==200 and 'error' not in events[-1],(contract,transport,route,extra,events)
                                assert server.calls==before+1,'Unexpected replay'
                                wire=server.received[-1]
                                assert wire['instructions']==base['instructions'] and wire['prompt_cache_key']==base['prompt_cache_key']
                                assert wire['client_metadata']['label']=='synthetic' and wire['parallel_tool_calls'] is True
                                if transport=='websocket':
                                    assert wire.get('stream') is True if contract=='codex-subscription' else 'stream' not in wire
                                else: assert wire['stream']==(contract=='codex-subscription' or route=='sse')
                                if contract=='codex-subscription':
                                    assert wire['store'] is False and wire['input']==[dict(role='user',content=base['input'])]
                                    if extra.get('service_tier', 'absent') is None: assert 'service_tier' not in wire
                                    assert all(key not in wire for key in ('temperature','top_p','max_output_tokens','metadata','truncation','prompt_cache_retention'))
                                else:
                                    assert wire['input']==base['input']
                                    assert all(wire[key]==value for key,value in extra.items())
                                if 'include' in extra: assert wire['include'] == extra['include']
                                if 'synthetic_future_field' in extra: assert wire['synthetic_future_field']=={'enabled':True}
                            # Only explicit constraints the subscription backend cannot honor fail before dispatch.
                            negative=([*unsupported]+([] if route=='native' else [dict(previous_response_id='synthetic-previous')]) if contract=='codex-subscription' else [])
                            for extra in negative:
                                before=server.calls;upgrades=server.upgrades;attempts=attempt_count(root)
                                status,events=call(ports['data'],route,{**base,**extra});total+=1
                                assert 'error' in events[-1] and (route=='native' or status==400),(contract,transport,route,extra,status,events)
                                assert server.calls==before and server.upgrades==upgrades and attempt_count(root)==attempts,'Rejected request admitted, connected or dispatched'
                        expected=attempt_count(root);deadline=time.monotonic()+5
                        while len(rows(root))!=expected or any(s=='intent' for s,_,_ in rows(root)):
                            assert time.monotonic()<deadline;time.sleep(.02)
                        assert all(s=='settled' and k=='succeeded' and u['inputTokens']==5 for s,k,u in rows(root)),rows(root)
                        print(f'PASS: {contract}/{transport}: exact wire fields, JSON/SSE/native, zero-attempt rejection and settled usage',flush=True)
                    finally:stop(process)
        print(f'PASS: {total} synthetic request-parameter operations; no credentials or live models',flush=True)
    finally:server.shutdown();server.server_close();worker.join(10)

if __name__=='__main__':main()
