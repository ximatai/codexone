#!/usr/bin/env python3
"""Unknown envelopes are inert, bounded and private; known terminals and objects stay strict."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from trial_provider import Server
from verify_protocol import TOKEN, connect, start, stop
from verify_upstream_events import Events, states
from verify_upstream_proxy import Proxy
from verify_websocket import dial, turn

PRIVATE='synthetic-private-extension-never-forward'


def extension():
    return dict(type='synthetic.extension',item=dict(id=PRIVATE,type='function_call',name=PRIVATE),
        response=dict(id=PRIVATE,status='completed',output=[],usage=dict(input_tokens=9999,output_tokens=9999)),
        error=dict(message=PRIVATE),delta=PRIVATE)


class Extensions(Events):
    def events(self,document):
        events=super().events(document);mode=self.server.extension_mode
        if mode=='only':return [extension()]*3
        if mode=='oversized':return [dict(type='synthetic.extension',data='x'*262145)]
        if mode=='stall':
            def drip():
                for _ in range(80):yield extension();time.sleep(.05)
            return drip()
        if mode=='failure':
            response={**events[0]['response'],'status':'failed','error':dict(code='synthetic',message=PRIVATE),
                'usage':dict(input_tokens=1,output_tokens=1,input_tokens_details=dict(cached_tokens=0))}
            return [extension(),events[0],dict(type='response.failed',response=response)]
        if mode=='image':return [events[0],dict(type='response.image_generation_call.in_progress',item_id=PRIVATE)]
        result=[extension()]
        for event in events:
            if event['type']=='response.completed':result.append(extension())
            result.append(event)
            if event['type'] in ('response.created','response.output_text.done'):result.append(extension())
        return result

    def do_POST(self):
        if self.server.extension_mode!='stall':return super().do_POST()
        self.accept_upstream_credential();self.close_connection=True
        document=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        events=self.events(document);self.send_response(200);self.send_header('Transfer-Encoding','chunked');self.end_headers()
        for event in events:
            body=('data: '+json.dumps(event)+'\n\n').encode()
            self.wfile.write(f'{len(body):x}\r\n'.encode()+body+b'\r\n');self.wfile.flush()
        self.wfile.write(b'0\r\n\r\n')


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);binary=str(parser.parse_args().binary.resolve())
    provider=Server(('127.0.0.1',0),['synthetic-events']);provider.RequestHandlerClass=Extensions;provider.scenario='ok'
    thread=threading.Thread(target=provider.serve_forever);thread.start()
    proxy=Proxy(provider.server_port);proxy_thread=threading.Thread(target=proxy.serve_forever);proxy_thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-extensions-') as temporary:
            owner=Path(temporary)
            for transport in ['http','websocket']:
                for mode in ['ok','only','stall','oversized','failure','image']:
                    provider.extension_mode=mode;root=owner/(transport+'-'+mode);root.mkdir(mode=0o700)
                    secret=root/'access';secret.write_text('synthetic-private-upstream-token-never-log');secret.chmod(0o600)
                    config=root/'identity.json';config.write_text(json.dumps(dict(principal='synthetic-extension',keyID='synthetic-key',keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-extension',identity='synthetic-identity',models=[dict(id='synthetic-events',inputMicrosPerMillion=0,outputMicrosPerMillion=0)],reservedMicros=1,upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1',upstreamTransport=transport,upstreamTokenFile=str(secret),executionTimeoutSeconds=5,firstResponseTimeoutSeconds=1,progressTimeoutSeconds=1)));config.chmod(0o600)
                    process,ports=start(binary,config,root,upstream_proxy=f'http://127.0.0.1:{proxy.server_address[1]}');before=provider.sequence
                    try:
                        began=time.monotonic();request=dict(model='synthetic-events',input=[dict(role='user',content='synthetic extension test')],stream=True)
                        status,body=connect(ports['data'],'POST','/v1/responses',request)
                        assert PRIVATE.encode() not in body
                        count=1
                        if mode=='ok':
                            assert status==200
                            events=[json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: ') and line[6:]!=b'[DONE]']
                            done=[e for e in events if e.get('type')=='response.completed'];assert len(done)==1
                            assert all(e.get('type')!='synthetic.extension' for e in events)
                            request['input']+=done[0]['response']['output']+[dict(role='user',content='synthetic next')]
                            status,body=connect(ports['data'],'POST','/v1/responses',request);assert status==200 and b'response.completed' in body and PRIVATE.encode() not in body
                            count+=1
                            if transport=='websocket':
                                with dial(ports['data']) as client:
                                    first=turn(client,dict(model='synthetic-events',input='synthetic native'))[-1]['response']
                                    assert turn(client,dict(model='synthetic-events',input='synthetic next',previous_response_id=first['id']))[-1]['type']=='response.completed'
                                count+=2
                            deadline=time.monotonic()+3
                            while len(states(root))!=count or any(s!='settled' for s,k,u in states(root)):
                                assert time.monotonic()<deadline;time.sleep(.02)
                        else:
                            assert b'response.completed' not in body
                            if mode=='stall':assert time.monotonic()-began<3,'Extension traffic renewed a progress deadline'
                        process.terminate();process.wait(10);logs=process.stdout.read()
                        assert provider.sequence==before+count
                        with sqlite3.connect(root/'state/core.sqlite') as db:
                            assert db.execute('SELECT count(*) FROM bindings WHERE raw_id=?',(PRIVATE,)).fetchone()[0]==0
                        rows=states(root)
                        if mode in ('ok','failure'):
                            assert len(rows)==count and all(s=='settled' and u and u['inputTokens']==1 and u['outputTokens']==1 for s,k,u in rows)
                            assert all(k==('succeeded' if mode=='ok' else 'failed') for s,k,u in rows)
                        else:assert len(rows)==1 and rows[0][0]=='unknown' and rows[0][2] is None
                        if mode=='ok':assert logs.count(b'Upstream extension isolated without protocol effects')==1
                        assert PRIVATE.encode() not in logs and b'synthetic-private-upstream-token-never-log' not in logs
                    finally:stop(process)
                print(f'PASS: {transport} extensions never forward/bind/settle/renew; known failure/image guards, byte limits, terminal evidence and full-window/native continuation remain enforced',flush=True)
    finally:
        proxy.close_owned();proxy_thread.join(5);provider.interrupt();provider.server_close();thread.join(5)


if __name__=='__main__':main()
