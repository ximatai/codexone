#!/usr/bin/env python3
"""Actual proxy HTTP/WS streams for nullable phase and known reasoning-text events."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from trial_provider import Server, response_events
from verify_protocol import TOKEN, connect, start, stop
from verify_upstream_proxy import Proxy, Observed
from verify_websocket import dial, turn


class Events(Observed):
    def send_header(self,name,value):
        # Reproduce the subscription's missing media header in the same real socket test.
        if name.lower()!='content-type':super().send_header(name,value)

    def events(self,document):
        if isinstance(document.get('input'),list) and len(document['input'])>1:
            history=document['input']
            assert any(item.get('type')=='reasoning' and item.get('encrypted_content','').startswith('synthetic-events-cipher-') for item in history)
            assert any(item.get('role')=='assistant' and 'phase' in item and item['phase'] is None for item in history)
            assert all('id' not in item for item in history)
        response=super().events(document)[-1]['response']
        message=response['output'][0];message['phase']=None
        reasoning=dict(type='reasoning',id='rs_'+response['id'],summary=[],content=[dict(type='reasoning_text',text='synthetic raw reasoning never log')],encrypted_content='synthetic-events-cipher-'+response['id'])
        response['output'].insert(0,reasoning)
        events=response_events(response)
        for index,event in enumerate(events):
            if event.get('type')=='response.output_item.added' and event['item']['type']=='reasoning':
                event['item'].pop('encrypted_content');event['item'].pop('content')
                raw=[
                    dict(type='response.content_part.added',item_id=reasoning['id'],part=dict(type='reasoning_text',text='')),
                    dict(type='response.reasoning_text.delta',item_id=reasoning['id'],content_index=0,output_index=0,delta='synthetic raw reasoning never log'),
                    dict(type='response.reasoning_text.done',item_id=reasoning['id'],content_index=0,text='synthetic raw reasoning never log'),
                    dict(type='response.content_part.done',item_id=reasoning['id'],part=dict(type='reasoning_text',text='synthetic raw reasoning never log')),
                ]
                events[index+1:index+1]=raw;break
        scenario=self.server.scenario
        if scenario=='phase':
            next(e for e in events if e.get('type')=='response.output_item.added' and e['item']['type']=='message')['item']['phase']=False
        elif scenario=='members':
            next(e for e in events if e.get('type')=='response.output_item.added')['item']['synthetic_unknown']='synthetic-private-rejected-event-value'
        elif scenario=='delta':
            next(e for e in events if e.get('type')=='response.reasoning_text.delta')['delta']={'file_id':'synthetic-private-rejected-event-value'}
        elif scenario=='index':
            next(e for e in events if e.get('type')=='response.reasoning_text.delta')['content_index']=-1
        elif scenario=='item-id':
            next(e for e in events if e.get('type')=='response.reasoning_text.delta')['item_id']=False
        elif scenario=='unknown-event':
            next(e for e in events if e.get('type')=='response.reasoning_text.delta')['type']='synthetic-private-rejected-event-value'
        elif scenario=='part':
            next(e for e in events if e.get('type')=='response.content_part.added')['part']['synthetic_unknown']='synthetic-private-rejected-event-value'
        elif scenario=='summary-part':
            next(e for e in events if e.get('type')=='response.content_part.added')['type']='response.reasoning_summary_part.added'
        if scenario!='ok':
            if scenario=='phase':bad=next(e for e in events if e.get('type')=='response.output_item.added' and e['item']['type']=='message')
            elif scenario=='members':bad=next(e for e in events if e.get('type')=='response.output_item.added')
            elif scenario in ('part','summary-part'):bad=next(e for e in events if e.get('type') in ('response.content_part.added','response.reasoning_summary_part.added'))
            else:bad=next(e for e in events if e.get('type') in ('response.reasoning_text.delta','synthetic-private-rejected-event-value'))
            return events[:events.index(bad)+1]
        return events


def states(root):
    with sqlite3.connect(root/'state/core.sqlite') as db:
        return [(state,json.loads(outcome)['kind'] if outcome else None,json.loads(usage) if usage else None) for state,outcome,usage in db.execute('SELECT state,outcome_json,usage_json FROM attempts ORDER BY rowid')]


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);binary=str(parser.parse_args().binary.resolve())
    provider=Server(('127.0.0.1',0),['synthetic-events']);provider.RequestHandlerClass=Events
    thread=threading.Thread(target=provider.serve_forever);thread.start()
    proxy=Proxy(provider.server_port);proxy_thread=threading.Thread(target=proxy.serve_forever);proxy_thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-events-') as temporary:
            owner=Path(temporary)
            for transport in ['http','websocket']:
                for scenario in ['ok','phase','members','delta','index','item-id','unknown-event','part','summary-part']:
                    provider.scenario=scenario;root=owner/(transport+'-'+scenario);root.mkdir(mode=0o700)
                    secret=root/'access';secret.write_text('synthetic-private-upstream-token-never-log');secret.chmod(0o600)
                    config=root/'identity.json';config.write_text(json.dumps(dict(principal='synthetic-events',keyID='synthetic-key',keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-events',identity='synthetic-identity',models=[dict(id='synthetic-events',inputMicrosPerMillion=0,outputMicrosPerMillion=0)],reservedMicros=1,upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1',upstreamTransport=transport,upstreamTokenFile=str(secret))));config.chmod(0o600)
                    process,ports=start(binary,config,root,upstream_proxy=f'http://127.0.0.1:{proxy.server_address[1]}')
                    before=provider.sequence
                    try:
                        request=dict(model='synthetic-events',input=[dict(role='user',content='synthetic events')],stream=True)
                        status,body=connect(ports['data'],'POST','/v1/responses',request)
                        assert b'synthetic-private-rejected-event-value' not in body
                        events=[json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: ') and line[6:]!=b'[DONE]']
                        if scenario=='ok':
                            assert status==200
                            done=[e for e in events if e.get('type')=='response.completed'];assert len(done)==1
                            assert any(e.get('type')=='response.reasoning_text.delta' for e in events)
                            request['input']+=done[0]['response']['output']+[dict(role='user',content='synthetic continuation')]
                            status,body=connect(ports['data'],'POST','/v1/responses',request)
                            assert status==200 and b'response.completed' in body
                            count=2
                            if transport=='websocket':
                                with dial(ports['data']) as client:
                                    first=turn(client,dict(model='synthetic-events',input='synthetic native'))[-1]['response']
                                    assert turn(client,dict(model='synthetic-events',input='synthetic next',previous_response_id=first['id']))[-1]['type']=='response.completed'
                                count+=2
                            deadline=time.monotonic()+3
                            while not (len(states(root))==count and all(s=='settled' and k=='succeeded' and u and u.get('completeness')=='complete' for s,k,u in states(root))):
                                assert time.monotonic()<deadline
                                time.sleep(.02)
                        else:
                            assert b'response.completed' not in body
                            errors=[e['error'] for e in events if e.get('type')=='error'];assert len(errors)==1
                            expected=('invalid_upstream_turn',) if transport=='websocket' and scenario=='item-id' else ('unsupported_upstream_event','unsupported_upstream_object')
                            assert errors[0]['code'] in expected,(transport,scenario,errors[0]['code'])
                            assert errors[0]['request_id'] in errors[0]['message'];count=1
                        process.terminate();process.wait(10);logs=process.stdout.read()
                        assert provider.sequence==before+count
                        if scenario!='ok':
                            assert states(root)[0][0]=='unknown' and states(root)[0][2] is None
                            reason=('upstream_message_phase' if scenario=='phase' else 'upstream_item_members' if scenario=='members' else 'upstream_part' if scenario in ('part','summary-part') else 'upstream_event')
                            if not (transport=='websocket' and scenario=='item-id'):assert ('reason='+reason).encode() in logs
                            assert b'code=other' not in logs
                        assert b'synthetic raw reasoning never log' not in logs and b'synthetic-private-rejected-event-value' not in logs
                        assert b'synthetic-private-upstream-token-never-log' not in logs
                    finally:stop(process)
                print(f'PASS: {transport} proxy headerless reasoning-text/nullable-phase full-window continuation; strict event/part/index/phase/ID rejection, private reasons and durable usage/unknown without replay',flush=True)
    finally:
        proxy.close_owned();proxy_thread.join(5);provider.interrupt();provider.server_close();thread.join(5)


if __name__=='__main__':main()
