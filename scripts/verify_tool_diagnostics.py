#!/usr/bin/env python3
"""Fixed tool rejection reasons over real HTTP/WS, with no dispatch or private-field logging."""
import argparse
import hashlib
import json
from pathlib import Path
import socket
import sqlite3
import tempfile
from verify_protocol import TOKEN, connect, start, stop
from verify_websocket import dial, receive, send


def cases():
    private='synthetic-private-tool-value-never-log'
    function=dict(type='function',name='synthetic_echo',description=private,parameters=dict(type='object'))
    namespace=dict(type='namespace',name='synthetic_ns',tools=[function])
    package=dict(type='additional_tools',role='developer',tools=[function])
    return private, [
        ('tools_container',dict(tools={})),
        ('tools_count',dict(tools=[{**function,'name':f'synthetic_{i}'} for i in range(65)])),
        ('tools_name',dict(tools=[{**function,'name':private+'!'}])),
        ('tools_description',dict(tools=[{**function,'description':False}])),
        ('tools_boolean',dict(tools=[{**function,'strict':private}])),
        ('tools_namespace',dict(tools=[{**namespace,'tools':[namespace]}])),
        ('tools_members',dict(tools=[{**function,'synthetic_private_field':private}])),
        ('tools_duplicate',dict(tools=[function,function])),
        ('tools_grammar',dict(tools=[dict(type='custom',name='synthetic_custom',format=dict(type='text',synthetic_private_field=private))])),
        ('tools_type',dict(tools=[dict(type=private,name=private)])),
        ('tools_builtin_search',dict(tools=[dict(type='web_search',synthetic_private_field=private)])),
        ('tools_discovery',dict(tools=[dict(type='tool_search',synthetic_private_field=private)])),
        ('tools_remote_mcp',dict(tools=[dict(type='mcp',server_label=private)])),
        ('tools_choice',dict(tools=[function],tool_choice=private)),
        ('tools_package',dict(input=[{**package,'role':'user'}])),
        ('tools_image',dict(input=[{**package,'tools':[dict(type='image_generation')]}])),
    ]


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    binary=str(parser.parse_args().binary.resolve());private,examples=cases()
    with tempfile.TemporaryDirectory(prefix='codexone-tool-reasons-') as tmp,socket.socket() as upstream:
        upstream.bind(('127.0.0.1',0));upstream.listen(8);upstream.settimeout(0.1)
        root=Path(tmp);config=root/'identity.json'
        config.write_text(json.dumps(dict(principal='synthetic-principal',keyID='synthetic-key',
            keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-tool-reasons',identity='fixture',
            reservedMicros=1,upstreamTransport='websocket',
            models=[dict(id='synthetic-text',inputMicrosPerMillion=0,outputMicrosPerMillion=0)],
            upstreamBaseURL=f'http://127.0.0.1:{upstream.getsockname()[1]}/v1')));config.chmod(0o600)
        process,ports=start(binary,config,root);ids=[]
        try:
            for index,(reason,change) in enumerate(examples):
                request=dict(model='synthetic-text',input=private,**{k:v for k,v in change.items() if k!='input'})
                if 'input' in change:request['input']=change['input']
                if index%2:
                    with dial(ports['data']) as sock:
                        send(sock,dict(type='response.create',**request),masked=True)
                        opcode,data=receive(sock);event=json.loads(data)
                        assert opcode==1 and event['type']=='error';error=event['error']
                else:
                    status,data=connect(ports['data'],'POST','/v1/responses',request)
                    assert status==400;error=json.loads(data)['error']
                assert error['code']=='unsupported_tools' and error['message']=='Gateway request failed. Reference: '+error['request_id']+'.'
                assert set(error)=={'type','code','message','request_id'} and private.encode() not in data
                ids.append((reason,error['request_id']))
            # Extra errors cannot exceed the shared diagnostic budget.
            for _ in range(4):
                assert connect(ports['data'],'POST','/v1/responses',dict(model='synthetic-text',input=private,tools={}))[0]==400
            with sqlite3.connect(root/'state/core.sqlite') as db:
                assert db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0]==0
                assert db.execute('SELECT COUNT(*) FROM bindings').fetchone()[0]==0
            try:
                connection,_=upstream.accept();connection.close();raise AssertionError('Rejected tools dispatched')
            except socket.timeout:pass
            process.terminate();process.wait(8);output=process.stdout.read()
            assert process.returncode==0 and output.count(b'Protocol request rejected')==16
            for reason,request_id in ids:
                assert any(('reason='+reason).encode() in line and ('request_id='+request_id).encode() in line for line in output.splitlines()), reason
            for value in [private,TOKEN,'synthetic_private_field','synthetic_echo','server_label',str(config)]:
                assert value.encode() not in output,value
        finally:stop(process)
    print('PASS: all 16 fixed tool reasons correlate HTTP/WS errors to bounded private-free logs; no upstream, attempt or binding')


if __name__=='__main__':main()
