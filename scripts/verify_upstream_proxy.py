#!/usr/bin/env python3
"""Explicit proxy sockets, no fallback/credential leak, bounded failure diagnostics and durable unknown."""
import argparse
import hashlib
import json
from pathlib import Path
import select
import selectors
import os
import http.client
import re
import ssl
import subprocess
import socket
import socketserver
import sqlite3
import tempfile
import threading
import time
from urllib.parse import parse_qs,urlsplit,urlencode
from http.server import ThreadingHTTPServer
from verify_account_admin_ui import SyntheticOAuth,ADMIN
from trial_provider import Handler, Server
from verify_protocol import TOKEN, connect, start, stop
from verify_websocket import dial, turn


class Proxy(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=False
    def __init__(self,target):
        super().__init__(('127.0.0.1',0),Tunnel)
        self.target=target;self.authority=f'127.0.0.1:{target}';self.mode='forward';self.requests=0
        self.guard=threading.Lock();self.connections=set();self.connected=threading.Event()
    def close_owned(self):
        self.shutdown()
        with self.guard: peers=list(self.connections)
        for peer in peers:
            try:peer.shutdown(socket.SHUT_RDWR)
            except OSError:pass
            peer.close()
        self.server_close()


class Tunnel(socketserver.BaseRequestHandler):
    def handle(self):
        peer=self.request;upstream=None
        with self.server.guard:self.server.connections.add(peer)
        try:
            peer.settimeout(8);header=bytearray()
            while not header.endswith(b'\r\n\r\n'):
                b=peer.recv(1)
                if not b:return
                header.extend(b);assert len(header)<16384
            lines=bytes(header).decode('ascii').split('\r\n');method,target,_=lines[0].split(' ')
            assert method=='CONNECT' and target==self.server.authority
            assert not any(line.lower().startswith(('authorization:','proxy-authorization:','cookie:')) for line in lines[1:])
            assert TOKEN.encode() not in header and b'synthetic-private' not in header
            with self.server.guard:self.server.requests+=1
            self.server.connected.set()
            if self.server.mode=='reject':peer.sendall(b'HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n');return
            if self.server.mode=='cut':return
            if self.server.mode=='stall':
                while peer.recv(1):pass
                return
            upstream=socket.create_connection(('127.0.0.1',self.server.target),timeout=3)
            with self.server.guard:self.server.connections.add(upstream)
            peer.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            while True:
                ready,_,_=select.select([peer,upstream],[],[],8)
                if not ready:return
                for source in ready:
                    data=source.recv(65536)
                    if not data:return
                    (upstream if source is peer else peer).sendall(data)
        except (OSError,EOFError):pass
        finally:
            with self.server.guard:
                self.server.connections.discard(peer)
                if upstream:self.server.connections.discard(upstream)
            if upstream:upstream.close()


class Observed(Handler):
    def accept_upstream_credential(self):
        assert self.headers.get('Authorization')=='Bearer synthetic-private-upstream-token-never-log'
        del self.headers['Authorization']
    def do_GET(self):
        self.accept_upstream_credential()
        return super().do_GET()
    def do_POST(self):
        self.accept_upstream_credential()
        media=getattr(self.server,'media',None)
        if media is not None:
            self.close_connection=True
            length=int(self.headers.get('Content-Length','0'));request=json.loads(self.rfile.read(length));events=self.events(request)
            body=''.join('data: '+json.dumps(event)+'\n\n' for event in events).encode()
            if media=='missing-html':body=b'<html>synthetic-private-untyped-body-never-forward</html>'
            if media=='missing-json':body=b'{"error":"synthetic-private-untyped-body-never-forward"}'
            if media=='missing-partial':body=('data: '+json.dumps(events[0])+'\n\n').encode()
            if media=='missing-malformed':body=b'data: synthetic-private-untyped-body-never-forward\n\n'
            if media=='missing-oversized':body=b'data: '+b'x'*1048577+b'\n\n'
            self.send_response(200)
            types={'empty':'','typed':'Text/Event-Stream; charset=UTF-8','json':'application/json','html':'text/html','prefix':'text/event-streaming','empty-essence':'; charset=UTF-8'}
            if media in types:self.send_header('Content-Type',types[media])
            self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
        if getattr(self.server,'reject',False):
            length=int(self.headers.get('Content-Length','0'));self.rfile.read(length)
            self.send_response(self.server.reject);self.send_header('Content-Type','application/json')
            body=json.dumps(dict(error=dict(code='unsupported_parameter',param='max_output_tokens',message='synthetic-private-provider-error-never-log'))).encode()
            self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
        return super().do_POST()


def ledger(root):
    with sqlite3.connect(root/'state/core.sqlite') as db:
        return list(db.execute('SELECT state FROM attempts'))



def authorization_and_quota(binary):
    provider=ThreadingHTTPServer(('127.0.0.1',0),SyntheticOAuth)
    provider.guard=threading.Lock();provider.control={};provider.calls=0;provider.quota_calls=0;provider.issued=[]
    provider_thread=threading.Thread(target=provider.serve_forever);provider_thread.start()
    proxy=Proxy(provider.server_port);proxy_thread=threading.Thread(target=proxy.serve_forever);proxy_thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-proxy-auth-') as temporary:
            root=Path(temporary);root.chmod(0o700);web=root/'web';web.mkdir(mode=0o700)
            (web/'assets').mkdir(mode=0o700);(web/'index.html').write_text('Synthetic API-only proxy fixture');(web/'assets/app.js').write_text('console.log("synthetic");')
            for name,value in [('admin',ADMIN),('master','6b'*32)]:
                path=root/name;path.write_text(value);path.chmod(0o600)
            process=subprocess.Popen([str(Path(binary).with_name('ExecutionProbe')),'--account-admin-ui',str(root),str(web),str(provider.server_port)],
                env=dict(PATH=os.defpath,CODEXONE_UPSTREAM_HTTP_PROXY=f'http://127.0.0.1:{proxy.server_address[1]}'),stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            output=b''
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout,selectors.EVENT_READ);deadline=time.monotonic()+12
                    while b'ADMIN_PORT ' not in output:
                        assert time.monotonic()<deadline and process.poll() is None
                        if selector.select(.1):output+=os.read(process.stdout.fileno(),4096)
                port=int(re.search(rb'ADMIN_PORT (\d+)',output)[1])
                def api(path,body):
                    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=8)
                    try:
                        connection.request('POST','/api/accounts/'+path,json.dumps(body),{'Authorization':'Bearer '+ADMIN,'Content-Type':'application/json'})
                        response=connection.getresponse();payload=response.read();assert response.status==200
                        return json.loads(payload)
                    finally:connection.close()
                flow=api('authorization',dict(target=None));query=parse_qs(urlsplit(flow['authorizationURL']).query)
                provider.control.update(challenge=query['code_challenge'][0],nonce=query['nonce'][0])
                callback='http://localhost:1455/auth/callback?'+urlencode(dict(state=query['state'][0],code='synthetic-code+/='))
                account=api('authorization/'+flow['flowID'],dict(callbackURL=callback))['account']
                assert provider.calls==1 and proxy.requests==1
                api(account['id']+'/observe',{});assert provider.quota_calls==1 and proxy.requests==2
                api(account['id']+'/refresh',dict(revision=account['revision']))
                assert provider.calls==2 and proxy.requests==3
                process.terminate();process.wait(10);output+=process.stdout.read()
                assert process.returncode==0
                for secret in [ADMIN,'6b'*32,*provider.issued,'synthetic-private-quota-marker']:
                    assert secret.encode() not in output
                    for file in (root/'state').glob('core.sqlite*'):assert secret.encode() not in file.read_bytes()
            finally:stop(process)
    finally:
        proxy.close_owned();proxy_thread.join(5);provider.shutdown();provider.server_close();provider_thread.join(5)
    print('PASS: OAuth code exchange, refresh and quota GET traverse the explicit proxy; secrets stay out of CONNECT/logs/ledger',flush=True)


def stream_media_cases(binary,provider,proxy,owner,source):
    for media in ['missing','empty','typed','json','html','prefix','empty-essence','missing-html','missing-json','missing-partial','missing-malformed','missing-oversized']:
        root=owner/('media-'+media);root.mkdir(mode=0o700)
        config=root/'identity.json';config.write_text(json.dumps({**source,'upstreamTransport':'http'}));config.chmod(0o600)
        provider.media=media;before=provider.sequence
        process,ports=start(binary,config,root,upstream_proxy=f'http://127.0.0.1:{proxy.server_address[1]}')
        try:
            success=media in ('missing','empty','typed');count=2 if media=='missing' else 1
            previous=None
            for _ in range(count):
                request=dict(model='synthetic-text',input='synthetic media test',stream=True)
                if previous:request['previous_response_id']=previous
                status,body=connect(ports['data'],'POST','/v1/responses',request)
                assert b'synthetic-private-untyped-body-never-forward' not in body
                if success:
                    assert status==200
                    events=[json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: ') and line[6:]!=b'[DONE]']
                    terminal=[e for e in events if e.get('type')=='response.completed'];assert len(terminal)==1
                    previous=terminal[0]['response']['id']
                else:assert b'response.completed' not in body
            if success:
                deadline=time.monotonic()+3
                while ledger(root)!=[('settled',)]*count:
                    assert time.monotonic()<deadline,ledger(root)
                    time.sleep(.02)
            process.terminate();process.wait(10);output=process.stdout.read()
            assert provider.sequence==before+count
            assert ledger(root)==[('settled' if success else 'unknown',)]*count
            if media=='missing':assert output.count(b'Upstream stream omitted media type; SSE validation required')==1
            if media in ('json','html','prefix','empty-essence'):
                expected={'json':'json','html':'html','prefix':'other','empty-essence':'other'}[media]
                assert b'upstream_status=200' in output and ('reason=upstream_media_type_'+expected).encode() in output
            assert b'synthetic-private-untyped-body-never-forward' not in output
            assert b'synthetic-private-upstream-token-never-log' not in output
        finally:stop(process)
    provider.media=None
    print('PASS: absent/empty stream media types retain SSE/continuation/usage validation; explicit wrong media, HTML/JSON, partial/malformed/oversized bodies fail without replay or raw output',flush=True)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    binary=str(parser.parse_args().binary.resolve())
    with tempfile.TemporaryDirectory(prefix='codexone-proxy-config-') as temporary:
        root=Path(temporary)
        for value in ['http://user:synthetic-private-proxy-secret@proxy.example:7890','http://proxy.example:80/path','socks5://proxy.example:7890']:
            checked=subprocess.run([binary,'--check-config'],env=dict(PATH=os.defpath,CODEXONE_DATA_DIRECTORY=str(root/'state'),CODEXONE_UPSTREAM_HTTP_PROXY=value),capture_output=True,timeout=8)
            assert checked.returncode!=0 and not (root/'state').exists()
            assert value.encode() not in checked.stdout+checked.stderr and b'synthetic-private-proxy-secret' not in checked.stdout+checked.stderr
        checked=subprocess.run([binary,'--check-config'],env=dict(PATH=os.defpath,HTTP_PROXY='synthetic-private-ambient-proxy',CODEXONE_UPSTREAM_HTTP_PROXY=''),capture_output=True,timeout=8)
        assert checked.returncode==0 and b'synthetic-private-ambient-proxy' not in checked.stdout+checked.stderr

    provider=Server(('127.0.0.1',0),['synthetic-text']);provider.RequestHandlerClass=Observed
    upstream_thread=threading.Thread(target=provider.serve_forever);upstream_thread.start()
    proxy=Proxy(provider.server_port);proxy_thread=threading.Thread(target=proxy.serve_forever);proxy_thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-proxy-') as temporary:
            owner=Path(temporary)
            for transport in ['http','websocket']:
                for mode in ['forward','reject','cut','stall','cancel']:
                    root=owner/(transport+'-'+mode);root.mkdir(mode=0o700)
                    secret=root/'upstream';secret.write_text('synthetic-private-upstream-token-never-log');secret.chmod(0o600)
                    config=root/'identity.json';config.write_text(json.dumps(dict(upstreamTokenFile=str(secret),principal='synthetic-principal',keyID='synthetic-key',keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-proxy',identity='synthetic-upstream',reservedMicros=1,upstreamTransport=transport,models=[dict(id='synthetic-text',inputMicrosPerMillion=0,outputMicrosPerMillion=0)],upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1',executionTimeoutSeconds=15,firstResponseTimeoutSeconds=10,progressTimeoutSeconds=10)));config.chmod(0o600)
                    proxy.mode='stall' if mode=='cancel' else mode;proxy.connected.clear();before=provider.sequence;tunnels=proxy.requests
                    process,ports=start(binary,config,root,upstream_proxy=f'http://127.0.0.1:{proxy.server_address[1]}')
                    try:
                        request=dict(model='synthetic-text',input='synthetic proxy test')
                        if mode=='cancel':
                            with socket.create_connection(('127.0.0.1',ports['data']),timeout=3) as client:
                                body=json.dumps(request).encode()
                                client.sendall((f'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n').encode()+body)
                                assert proxy.connected.wait(3)
                                process.terminate();process.wait(10)
                            assert provider.sequence==before
                        elif mode=='forward':
                            for streaming in [False,True]:
                                status,body=connect(ports['data'],'POST','/v1/responses',{**request,'stream':streaming})
                                assert status==200 and b'response' in body
                            if transport=='websocket':
                                with dial(ports['data']) as client:
                                    response=turn(client,request)[-1]['response']
                                    assert turn(client,{**request,'previous_response_id':response['id']})[-1]['type']=='response.completed'
                            assert proxy.requests>tunnels and provider.sequence>before
                            # The terminal frame precedes the owned finalizer's durable completion.
                            # Require bounded convergence without restart or another dispatch.
                            expected=4 if transport=='websocket' else 2
                            deadline=time.monotonic()+3
                            while True:
                                states=ledger(root)
                                if len(states)==expected and all(s=='settled' for (s,) in states):break
                                assert time.monotonic()<deadline,states
                                time.sleep(.02)
                        else:
                            began=time.monotonic();status,body=connect(ports['data'],'POST','/v1/responses',request)
                            assert status==502 and time.monotonic()-began<9
                            error=json.loads(body)['error'];assert set(error)=={'type','code','message','request_id'}
                            assert error['request_id'] in error['message'] and provider.sequence==before
                            if mode=='reject':assert error['code']=='upstream_proxy_authentication_required',error['code']
                            deadline=time.monotonic()+3
                            while ledger(root)!=[('unknown',)]:
                                assert time.monotonic()<deadline,(transport,mode,ledger(root))
                                time.sleep(.02)
                        if process.poll() is None:process.terminate();process.wait(10)
                        output=process.stdout.read()
                        for private in [TOKEN,'synthetic-private-provider-error-never-log','synthetic-private-upstream-token-never-log',str(config),f'http://127.0.0.1:{proxy.server_address[1]}']:assert private.encode() not in output
                        # Reopening read-only is evidence the ledger survives owner shutdown.
                        states=ledger(root)
                        if mode=='forward':assert len(states)==expected and all(s=='settled' for (s,) in states),states
                        else:assert states==[('unknown',)],states
                    finally:stop(process)
                    print(f'PASS: explicit {transport} proxy {mode}; no direct fallback, private output or lost ledger',flush=True)
            proxy.mode='forward'
            stream_media_cases(binary,provider,proxy,owner,json.loads(config.read_text()))
            # A provider 400 is distinct from a proxy 407; source status and fixed reason remain server-side.
            proxy.mode='forward';provider.reject=400
            root=owner/'provider-rejection';root.mkdir(mode=0o700)
            source=json.loads(config.read_text());source['upstreamTransport']='http'
            config=root/'identity.json';config.write_text(json.dumps(source));config.chmod(0o600)
            process,ports=start(binary,config,root,upstream_proxy=f'http://127.0.0.1:{proxy.server_address[1]}')
            try:
                status,body=connect(ports['data'],'POST','/v1/responses',dict(model='synthetic-text',input='synthetic rejection',max_output_tokens=128))
                # The provider's actionable 400 reaches the client; its text never enters logs.
                assert status==400;error=json.loads(body)['error'];assert error['code']=='unsupported_parameter' and error['param']=='max_output_tokens'
                assert 'upstream_status' not in error and 'reason' not in error
                process.terminate();process.wait(10);output=process.stdout.read()
                assert b'upstream_status=400' in output and b'provider_code=unsupported_parameter' in output
                assert error['request_id'].encode() in output and b'synthetic-private-provider-error-never-log' not in output
                assert ledger(root)==[('unknown',)]
            finally:stop(process)
            print('PASS: proxy and provider rejections correlate by UUID; provider errors reach the client, never the logs',flush=True)
            # A successful CONNECT never weakens target TLS or permits the bearer to reach a bad certificate.
            tlsroot=owner/'tls';tlsroot.mkdir(mode=0o700)
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=synthetic.invalid',
                '-keyout',str(tlsroot/'key.pem'),'-out',str(tlsroot/'cert.pem')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(str(tlsroot/'cert.pem'),str(tlsroot/'key.pem'))
            class InvalidTLS(socketserver.BaseRequestHandler):
                def handle(self):
                    self.server.handshakes+=1
                    try:
                        with context.wrap_socket(self.request,server_side=True) as channel:
                            channel.settimeout(3);self.server.applicationBytes+=len(channel.recv(4096))
                    except (ssl.SSLError,OSError):pass
            invalid=socketserver.ThreadingTCPServer(('127.0.0.1',0),InvalidTLS);invalid.applicationBytes=0;invalid.handshakes=0
            invalid_thread=threading.Thread(target=invalid.serve_forever);invalid_thread.start()
            proxy.target=invalid.server_address[1];proxy.authority='chatgpt.com:443'
            try:
                for transport in ['http','websocket']:
                    root=owner/('tls-'+transport);root.mkdir(mode=0o700)
                    value={**source,'upstreamTransport':transport,'upstreamBaseURL':'https://chatgpt.com/backend-api/codex'}
                    config=root/'identity.json';config.write_text(json.dumps(value));config.chmod(0o600)
                    process,ports=start(binary,config,root,upstream_proxy=f'http://127.0.0.1:{proxy.server_address[1]}')
                    try:
                        before=invalid.handshakes
                        status,body=connect(ports['data'],'POST','/v1/responses',dict(model='synthetic-text',input='synthetic invalid TLS'))
                        assert status==502 and invalid.applicationBytes==0 and invalid.handshakes==before+1
                        process.terminate();process.wait(10);output=process.stdout.read()
                        assert b'synthetic-private-upstream-token-never-log' not in output and ledger(root)==[('unknown',)]
                    finally:stop(process)
                print('PASS: HTTP/WSS CONNECT retains target TLS verification; invalid certificate receives no bearer or application data',flush=True)
            finally:invalid.shutdown();invalid.server_close();invalid_thread.join(5)

    finally:
        proxy.close_owned();proxy_thread.join(5);provider.interrupt();provider.server_close();upstream_thread.join(5)
    assert not proxy_thread.is_alive() and not upstream_thread.is_alive() and not proxy.connections
    authorization_and_quota(binary)


if __name__=='__main__':main()
