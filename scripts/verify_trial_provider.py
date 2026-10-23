#!/usr/bin/env python3
"""Actual gateway to the bounded trial fixture; no account or real provider."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading
from trial_provider import Server, TEXT
from verify_protocol import TOKEN, connect, latest, start, stop
from verify_websocket import dial, receive, turn


def verify_tool_evidence():
    from verify_default_client import MODEL, ScriptedTrial
    server=Server(('127.0.0.1',0),[MODEL]);server.RequestHandlerClass=ScriptedTrial
    thread=threading.Thread(target=server.serve_forever);thread.start()
    def post(document):
        connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=5)
        try:
            connection.request('POST','/v1/responses',json.dumps(document),{'Content-Type':'application/json'})
            response=connection.getresponse();body=response.read();return response.status,body
        finally:connection.close()
    try:
        for tool in ('sleep','exec_command'):
            declaration=dict(type='function',name=tool,parameters=dict(type='object'))
            if tool=='sleep':declaration=dict(type='namespace',name='clock',tools=[declaration])
            for compact in (False,True):
                for succeeds in (False,True):
                    server.observed=[];server.tool_sent=False;server.tool_name=None;server.tool_success_seen=False;server.compactions=0
                    assert post(dict(model=MODEL,input=[],tools=[declaration]))[0]==200
                    output=('Wall time: 0.001 seconds\nSleep completed.' if tool=='sleep' else
                        'Process exited with code 0\nOutput:\nsynthetic-tool-success') if succeeds else 'Synthetic tool execution failed'
                    items=[dict(type='function_call_output',call_id='call_default_client',output=output)]
                    if compact:items.append(dict(type='compaction_trigger'))
                    status,body=post(dict(model=MODEL,input=items,tools=[declaration]))
                    assert status==(200 if succeeds else 400)
                    assert server.tool_success_seen==succeeds and server.compactions==(1 if compact and succeeds else 0)
                    if succeeds:assert json.loads(body)['status']=='completed'
    finally:server.interrupt();server.server_close();thread.join(5)
    assert not thread.is_alive() and not server.sockets


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    binary=str(parser.parse_args().binary.resolve())
    server=Server(('127.0.0.1',0),['synthetic-text'])
    thread=threading.Thread(target=server.serve_forever);thread.start()
    try:
        for transport in ('http','websocket'):
            with tempfile.TemporaryDirectory(prefix='codexone-trial-fixture-') as temporary:
                root=Path(temporary);config=root/'identity.json'
                config.write_text(json.dumps(dict(principal='synthetic-principal',keyID='synthetic-key',
                    keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-trial',identity='fixture',
                    reservedMicros=1,upstreamTransport=transport,
                    models=[dict(id='synthetic-text',inputMicrosPerMillion=0,outputMicrosPerMillion=0)],
                    upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1')));config.chmod(0o600)
                process,ports=start(binary,config,root)
                try:
                    request=dict(model='synthetic-text',input='Synthetic private text must never be echoed.')
                    status,body=connect(ports['data'],'POST','/v1/responses',request)
                    assert status==200 and TEXT.encode() in body and b'private text' not in body
                    request['stream']=True
                    status,body=connect(ports['data'],'POST','/v1/responses',request)
                    assert status==200 and b'response.completed' in body and TEXT.encode() in body
                    if transport=='websocket':
                        with dial(ports['data']) as sock:
                            events=turn(sock,dict(model='synthetic-text',input='synthetic'))
                            assert events[-1]['type']=='response.completed' and TEXT in json.dumps(events)
                    status,body=connect(ports['data'],'POST','/v1/responses/compact',dict(model='synthetic-text',input=[]))
                    assert status==200 and b'response.compaction' in body
                    latest(root/'state/core.sqlite','settled')
                finally:stop(process)
    finally:server.interrupt();server.server_close();thread.join(3)
    assert not thread.is_alive() and not server.sockets
    # Exercise the actual signal owner while a WebSocket client is waiting idle.
    with socket.socket() as probe:probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
    child=subprocess.Popen(['python3',str(Path(__file__).with_name('trial_provider.py')),
        '--port',str(port),'--model','synthetic-text'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        assert select.select([child.stdout],[],[],10)[0] and child.stdout.readline()==b'SYNTHETIC_READY\n'
        with dial(port,authorized=False) as sock:
            child.terminate();child.wait(5)
            assert child.returncode==0 and sock.recv(1)==b''
        assert child.stderr.read()==b''
    finally:
        if child.poll() is None:child.kill();child.wait(5)
    verify_tool_evidence()
    print('PASS: trial fixture HTTP JSON/SSE, native/bridge WS, compact, no input echo, bounded owners and idle-WS SIGTERM cleanup; failed tool results cannot pass normal/compaction client fixtures')


if __name__=='__main__':main()
