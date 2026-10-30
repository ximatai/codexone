#!/usr/bin/env python3
"""Lite socket boundary: synthetic trial provider, ordered forwarding and no authority from local IDs."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
from trial_provider import Handler, Server, response_events
from verify_protocol import TOKEN, connect, start, stop
from verify_websocket import dial, turn, send, receive

MODEL='synthetic-text'
LITE_KEY='ws_request_header_x_openai_internal_codex_responses_lite'
TOOL=dict(type='function',name='synthetic_echo',description='é'*32769,parameters=dict(type='object'))
PACKAGE=dict(type='additional_tools',role='developer',id='at_synthetic_local',tools=[TOOL])
INPUT=[dict(role='developer',content='synthetic-before'),PACKAGE,dict(role='user',content='synthetic-after')]


class Observed(Handler):
    def events(self,document):
        if getattr(self.server,'expected_large',None) is not None:
            expected=self.server.expected_large
            assert document['input']==expected['input'] and document['tools']==expected['tools']
            return super().events(document)
        if getattr(self.server,'incremental',False):
            step=getattr(self,'step',0);self.step=step+1
            if step==0:
                assert document['generate'] is False
            else:
                assert 'tools' not in document and document['previous_response_id']==self.previous
                assert document['client_metadata'][LITE_KEY]=='true'
                assert document['input']==([dict(role='user',content='synthetic-next')] if step==1 else
                    [dict(type='function_call_output',call_id='call_lite',output='synthetic-result')])
                response=super().events(document)[-1]['response'];self.previous=response['id']
                if step==1:
                    response['output']=[dict(type='function_call',id='fc_lite',call_id='call_lite',
                        name='synthetic_echo',arguments='{}')]
                return response_events(response)
        expected=copy.deepcopy(INPUT);expected[1].pop('id')
        assert document['input']==expected and 'tools' not in document
        if self.command=='POST':assert self.headers.get('x-openai-internal-codex-responses-lite')=='true'
        else:assert document['client_metadata'][LITE_KEY]=='true'
        events=super().events(document);self.previous=events[-1]['response']['id']
        return events


def counts(root):
    with sqlite3.connect(root/'state/core.sqlite') as db:
        return (db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0],
            db.execute('SELECT COUNT(*) FROM bindings').fetchone()[0])


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    binary=str(parser.parse_args().binary.resolve())
    server=Server(('127.0.0.1',0),[MODEL]);server.RequestHandlerClass=Observed
    thread=threading.Thread(target=server.serve_forever);thread.start()
    try:
        for transport in ('http','websocket'):
            with tempfile.TemporaryDirectory(prefix='codexone-lite-') as tmp:
                root=Path(tmp);config=root/'identity.json'
                config.write_text(json.dumps(dict(principal='synthetic-principal',keyID='synthetic-key',
                    keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-lite',identity='fixture',
                    reservedMicros=1,models=[dict(id=MODEL,inputMicrosPerMillion=0,outputMicrosPerMillion=0)],
                    upstreamTransport=transport,upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1')))
                config.chmod(0o600);process,ports=start(binary,config,root)
                try:
                    for prefix in ('/v1','/backend-api/codex'):
                        for streaming in (False,True):
                            status,body=connect(ports['data'],'POST',prefix+'/responses',dict(model=MODEL,input=INPUT,stream=streaming))
                            assert status==200 and b'response' in body
                        status,body=connect(ports['data'],'POST',prefix+'/responses/compact',dict(model=MODEL,input=INPUT))
                        assert status==200 and json.loads(body)['output'][0]['type']=='compaction', {'status':status,'error':json.loads(body).get('error',{}).get('code')}
                        if transport=='websocket':
                            with dial(ports['data'],path=prefix+'/responses') as sock:
                                events=turn(sock,dict(model=MODEL,input=INPUT))
                                assert events[-1]['type']=='response.completed'
                    # Long function/custom/namespace descriptions must arrive intact, not truncated.
                    server.expected_large=dict(input='synthetic-large-top',tools=[dict(type='namespace',name='synthetic_ns',
                        description='n'*65537,tools=[TOOL,dict(type='custom',name='synthetic_custom',description='c'*65537)])])
                    try:
                        for prefix in ('/v1','/backend-api/codex'):
                            for streaming in (False,True):
                                status,body=connect(ports['data'],'POST',prefix+'/responses',dict(model=MODEL,stream=streaming,**server.expected_large))
                                assert status==200 and b'response' in body
                            if transport=='websocket':
                                with dial(ports['data'],path=prefix+'/responses') as sock:
                                    assert turn(sock,dict(model=MODEL,**server.expected_large))[-1]['type']=='response.completed'
                    finally:server.expected_large=None
                    if transport=='websocket':
                        server.incremental=True
                        with dial(ports['data']) as sock:
                            warmup=turn(sock,dict(model=MODEL,input=INPUT,generate=False))[-1]['response']
                            called=turn(sock,dict(model=MODEL,input=[dict(role='user',content='synthetic-next')],
                                previous_response_id=warmup['id']))[-1]['response']
                            assert called['output'][0]['name']=='synthetic_echo'
                            done=turn(sock,dict(model=MODEL,input=[dict(type='function_call_output',call_id='call_lite',output='synthetic-result')],
                                previous_response_id=called['id']))
                            assert done[-1]['type']=='response.completed'
                        server.incremental=False
                    before=counts(root);calls=server.sequence
                    # Only gateway-owned constraints reject: image generation outside its permissioned
                    # declaration, unowned provider references and the complete request size.
                    invalid=[dict(model=MODEL,input=[{**PACKAGE,'tools':[dict(type='image_generation')]}]),
                        dict(model=MODEL,input=[{**PACKAGE,'tools':[dict(type='namespace',name='synthetic_ns',tools=[dict(type='image_generation')])]}]),
                        dict(model=MODEL,input=[PACKAGE],previous_response_id=PACKAGE['id']),
                        dict(model=MODEL,input=[PACKAGE,dict(type='item_reference',id='synthetic-unowned-item')])]
                    oversized=dict(model=MODEL,input='x'*33554433)
                    try:
                        status,body=connect(ports['data'],'POST','/v1/responses',oversized);assert status==413
                    except (BrokenPipeError,ConnectionResetError):pass  # Rejected before the body finished.
                    for request in invalid:
                        status,_=connect(ports['data'],'POST','/v1/responses',request)
                        assert status in (400,403,404), status
                        if transport=='websocket':
                            with dial(ports['data']) as sock:
                                send(sock,dict(type='response.create',**request),masked=True,maximum_bytes=8388608)
                                opcode,data=receive(sock);event=json.loads(data)
                                assert opcode==1 and event['type']=='error'
                    assert counts(root)==before and server.sequence==calls, 'Rejected declaration/reference dispatched or changed ownership'
                    print(f'PASS: Lite {transport}, both prefixes, long descriptions forwarded intact, ordered forwarding, {len(invalid)*(2 if transport=="websocket" else 1)+1} rejection cases without dispatch',flush=True)
                finally:stop(process)
    finally:server.interrupt();server.server_close();thread.join(5)
    assert not thread.is_alive() and not server.sockets


if __name__=='__main__':main()
