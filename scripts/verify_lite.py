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
TOOL=dict(type='function',name='synthetic_echo',description='é'*16384,parameters=dict(type='object'))
PACKAGE=dict(type='additional_tools',role='developer',id='at_synthetic_local',tools=[TOOL])
INPUT=[dict(role='developer',content='synthetic-before'),PACKAGE,dict(role='user',content='synthetic-after')]


class Observed(Handler):
    def events(self,document):
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
                            calls=server.sequence;before=counts(root)
                            send(sock,dict(type='response.create',stream_id='synthetic-other-lane',model=MODEL,input=[],
                                previous_response_id=done[-1]['response']['id'],
                                tool_choice=dict(type='function',name='synthetic_echo')),masked=True)
                            event=json.loads(receive(sock)[1])
                            assert event['type']=='error' and event['stream_id']=='synthetic-other-lane'
                            assert server.sequence==calls and counts(root)==before
                        server.incremental=False
                        # Another connection cannot reuse the previous lane's declaration scope.
                        calls=server.sequence
                        with dial(ports['data']) as sock:
                            send(sock,dict(type='response.create',model=MODEL,input=[],previous_response_id=called['id'],
                                tool_choice=dict(type='function',name='synthetic_echo')),masked=True)
                            assert json.loads(receive(sock)[1])['type']=='error'
                        assert server.sequence==calls
                    before=counts(root);calls=server.sequence
                    invalid=[]
                    for change in [dict(role='user'),dict(tools=None),dict(id=False),dict(private='synthetic'),
                            dict(tools=[dict(type='image_generation')]),dict(tools=[dict(type='web_search')]),
                            dict(tools=[dict(type='tool_search')]),dict(tools=[{**TOOL,'description':'x'*32769}]),
                            dict(tools=[TOOL,TOOL]),dict(tools=[{**TOOL,'name':f'synthetic_{i}','description':'synthetic'} for i in range(65)])]:
                        package={**PACKAGE,**change};invalid.append(dict(model=MODEL,input=[package]))
                    invalid.extend([dict(model=MODEL,input=[PACKAGE],tools=[TOOL]),
                        dict(model=MODEL,input=[PACKAGE],tools=None),
                        dict(model=MODEL,input=[PACKAGE,dict(type='function_call_output',call_id='call_unknown',output='synthetic')]),
                        dict(model=MODEL,input=[PACKAGE],previous_response_id=PACKAGE['id'])])
                    for request in invalid:
                        status,_=connect(ports['data'],'POST','/v1/responses',request)
                        assert status in (400,403,404), status
                        if transport=='websocket':
                            with dial(ports['data']) as sock:
                                send(sock,dict(type='response.create',**request),masked=True)
                                opcode,data=receive(sock);event=json.loads(data)
                                assert opcode==1 and event['type']=='error'
                    assert counts(root)==before and server.sequence==calls, 'Rejected declaration/reference dispatched or changed ownership'
                    print(f'PASS: Lite {transport}, both prefixes, 32KiB UTF-8 description, ordered forwarding, {len(invalid)*(2 if transport=="websocket" else 1)} rejection cases without dispatch',flush=True)
                finally:stop(process)
    finally:server.interrupt();server.server_close();thread.join(5)
    assert not thread.is_alive() and not server.sockets


if __name__=='__main__':main()
