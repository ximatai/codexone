#!/usr/bin/env python3
"""Actual HTTP/WS long-turn and timeout/cancellation checks with an owned synthetic provider."""
import argparse
import base64
import hashlib
import http.client
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import json
from pathlib import Path
import select
import socket
import sqlite3
import tempfile
import threading
import time
from verify_protocol import TOKEN, start, stop, latest, connect
from verify_websocket import receive, send, dial


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def do_GET(self): self.owned(True)
    def do_POST(self): self.owned(False)
    def owned(self, ws):
        self.close_connection = True
        self.connection.settimeout(10)
        with self.server.guard: self.server.active += 1
        try:
            if ws:
                key = self.headers['Sec-WebSocket-Key']
                accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.send_response(101); self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
                self.send_header('Sec-WebSocket-Accept', accept); self.end_headers()
                opcode, data = receive(self.connection, masked=True); assert opcode == 1
                document = json.loads(data)
            else:
                n = int(self.headers.get('Content-Length', '0')); assert n <= 524288
                document = json.loads(self.rfile.read(n))
            with self.server.guard:
                self.server.calls += 1; index = self.server.calls
            case = document['input']
            if self.path.endswith('/compact'):
                body = json.dumps({'object': 'response.compaction', 'output': [], 'usage': {
                    'input_tokens': 1, 'output_tokens': 0, 'input_tokens_details': {'cached_tokens': 0}}}).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body); return
            if case == 'json-silent' and not ws:
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
                self.wfile.write(b'{'); self.wfile.flush(); self.wait_close(); return
            if case == 'first-silent':
                self.wait_close(); return
            if not ws:
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
            item = {'id': f'msg_long_{index}', 'type': 'message', 'role': 'assistant', 'status': 'completed',
                    'content': [{'type': 'output_text', 'text': '', 'annotations': []}]}
            response = {'id': f'resp_long_{index}', 'status': 'in_progress', 'output': [], 'usage': None}
            def emit(event):
                if ws: send(self.connection, event)
                else:
                    self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode()); self.wfile.flush()
            emit({'type': 'response.created', 'response': response})
            emit({'type': 'response.output_item.added', 'output_index': 0, 'item': item})
            if case in ('idle', 'cancel'):
                self.wait_close(); return
            began = time.monotonic(); count = 0
            while time.monotonic()-began < (self.server.duration if case == 'progress' else 8):
                if select.select([self.connection], [], [], 0.1)[0]:
                    data = self.connection.recv(1024)
                    if not data or ws and data[0] & 15 == 8:
                        self.server.closed.set(); return
                    # Native client pongs do not count as model progress.
                if case == 'comments':
                    if ws: send(self.connection, b'heartbeat', opcode=9)
                    else: self.wfile.write(b': synthetic keepalive\n\n'); self.wfile.flush()
                elif case == 'empty-delta': emit({'type': 'response.output_text.delta', 'item_id': item['id'], 'output_index': 0, 'content_index': 0, 'delta': ''})
                elif case == 'status-only': emit({'type': 'response.in_progress', 'response': response})
                else:
                    count += 1
                    emit({'type': 'response.output_text.delta', 'item_id': item['id'], 'output_index': 0,
                          'content_index': 0, 'delta': '.'})
                time.sleep(0.2)
            item['content'][0]['text'] = '.'*count
            emit({'type': 'response.output_item.done', 'output_index': 0, 'item': item})
            emit({'type': 'response.completed', 'response': {**response, 'status': 'completed', 'output': [item],
                'usage': {'input_tokens': 5, 'output_tokens': count, 'input_tokens_details': {'cached_tokens': 0}}}})
            if ws: self.wait_close()
        except (BrokenPipeError, ConnectionResetError): self.server.closed.set()
        except Exception as exc:
            with self.server.guard: self.server.failures.append(type(exc).__name__)
        finally:
            with self.server.guard: self.server.active -= 1
    def wait_close(self):
        self.connection.settimeout(self.server.duration+10)
        while True:
            data = self.connection.recv(1024)
            if not data or data[0] & 15 == 8:
                self.server.closed.set(); return


def run(binary, transport, duration):
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    provider.daemon_threads = False
    provider.guard=threading.Lock(); provider.closed=threading.Event(); provider.failures=[]
    provider.active=provider.calls=0; provider.duration=duration
    thread=threading.Thread(target=provider.serve_forever); thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-long-turn-') as temporary:
            root=Path(temporary)
            base={'principal':'synthetic-principal','keyID':'synthetic-key','keySHA256':hashlib.sha256(TOKEN.encode()).hexdigest(),
                'namespace':'synthetic-provider','identity':'synthetic-account','reservedMicros':1,
                'models':[{'id':'synthetic-text','inputMicrosPerMillion':1,'outputMicrosPerMillion':1}],
                'upstreamBaseURL':f'http://127.0.0.1:{provider.server_port}/v1',
                'executionTimeoutSeconds':max(140,duration+10),'firstResponseTimeoutSeconds':5,'progressTimeoutSeconds':3}
            if transport != 'http': base['upstreamTransport']='websocket'
            records=[]
            for case in ('progress','first-silent','idle','comments','status-only','empty-delta','total','cancel','compact') + (('json-silent',) if transport=='http' else ()):
                value=dict(base)
                if case=='first-silent': value['firstResponseTimeoutSeconds']=1
                if case in ('idle','comments','status-only','empty-delta','json-silent'): value['progressTimeoutSeconds']=1
                if case=='total':
                    value.update(executionTimeoutSeconds=2,firstResponseTimeoutSeconds=1,progressTimeoutSeconds=1)
                directory=root/case; directory.mkdir(); config=directory/'identity.json'
                config.write_text(json.dumps(value)); config.chmod(0o600)
                provider.closed.clear(); before=provider.calls
                gateway,ports=start(str(binary),config,directory)
                began=time.monotonic()
                try:
                    request={'model':'synthetic-text','input':case,'stream':case not in ('compact','json-silent')}
                    if case=='compact': request.pop('stream')
                    if transport=='native' and case!='compact':
                        sock=dial(ports['data']);sock.settimeout(duration+15)
                        send(sock,{'type':'response.create','model':'synthetic-text','input':case},masked=True)
                        messages=[]
                        try:
                            while True:
                                try: opcode,data=receive(sock,masked=False)
                                except EOFError:
                                    raise AssertionError((transport,case,'socket ended before expected terminal'))
                                if opcode==8: break
                                if opcode==9: send(sock,data,opcode=10,masked=True);continue
                                assert opcode==1
                                event=json.loads(data);messages.append(event)
                                if case=='cancel':
                                    assert event.get('type')=='response.created', 'Cancellation requires a live response'
                                    break
                                if event.get('type') in ('response.completed','error'):break
                        finally: sock.close()
                        body=json.dumps(messages).encode()
                    else:
                        c=http.client.HTTPConnection('127.0.0.1',ports['data'],timeout=duration+15)
                        try:
                            c.request('POST','/v1/responses/compact' if case=='compact' else '/v1/responses',json.dumps(request),{'Authorization':'Bearer '+TOKEN,'Content-Type':'application/json'})
                            r=c.getresponse()
                            if case=='cancel':
                                assert r.status==200 and r.getheader('Content-Type','').startswith('text/event-stream')
                                body=b''
                                while True:
                                    line=r.readline(262145)
                                    assert line and len(line)<=262144, 'Missing bounded created event'
                                    if line.startswith(b'data: '):
                                        event=json.loads(line[6:])
                                        assert event.get('type')=='response.created', 'Cancellation requires a live response'
                                        break
                            else: body=r.read()
                            r.close()
                        finally:c.close()
                    elapsed=time.monotonic()-began
                    if case=='compact':
                        assert b'response.compaction' in body and elapsed<5
                        latest(directory/'state/core.sqlite','settled')
                    elif case=='progress':
                        assert b'response.completed' in body and elapsed>=duration
                        latest(directory/'state/core.sqlite','settled')
                    else:
                        expected={'first-silent':b'execution_first_response_timeout','total':b'execution_deadline_exceeded',
                                  'idle':b'execution_progress_timeout','comments':b'execution_progress_timeout',
                                  'status-only':b'execution_progress_timeout','empty-delta':b'execution_progress_timeout','json-silent':b'execution_progress_timeout'}
                        if case!='cancel': assert expected[case] in body, (transport,case,'wrong timeout classification')
                        assert elapsed < (4 if case=='total' else 3)
                        assert provider.closed.wait(5),'Provider socket not closed'
                        latest(directory/'state/core.sqlite','unknown')
                    assert provider.calls-before==1,'Unexpected upstream replay'
                    records.append({'case':case,'seconds':round(elapsed,3),'upstreamCalls':1})
                    print('PASS:',transport,case,round(elapsed,3),flush=True)
                finally:
                    stop(gateway)
                    deadline=time.monotonic()+5
                    while provider.active and time.monotonic()<deadline: time.sleep(0.02)
                    assert provider.active==0, "Fixture handler did not finish"
            assert not provider.failures,provider.failures
            return {'transport':transport,'longSingleTurn':duration>=125,'cases':records}
    finally:
        provider.shutdown();provider.server_close();thread.join(3)
        assert not thread.is_alive() and provider.active==0 and not provider.failures


def main():
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--duration',type=int,default=125);p.add_argument('--output',type=Path,required=True)
    args=p.parse_args();assert 3<=args.duration<=300 and not args.output.exists()
    report={'scriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'results':[run(args.binary.resolve(),t,args.duration) for t in ('http','bridge','native')]}
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
    print('PASS: actual long single-turn HTTP/bridge/native WS and first/progress/total/heartbeat/cancel boundaries')


if __name__=='__main__':main()
