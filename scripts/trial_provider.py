#!/usr/bin/env python3
"""Bounded synthetic-only trial upstream. Never forwards, echoes, or logs client content."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import signal
import socket
import threading
import uuid
from verify_websocket import receive, send

TEXT = 'CodexOne synthetic connectivity test passed. No real model or subscription was called.'


def response_events(response):
    """Shared actual fixture serializer, including the terminal consumed by real clients."""
    result=[dict(type='response.created',response={**response,'status':'in_progress','output':[],'usage':None})]
    for index,item in enumerate(response['output']):
        added={**item,'status':'in_progress'}
        kind=item['type']
        if kind=='message':added['content']=[]
        if kind=='function_call':added['arguments']=''
        if kind=='custom_tool_call':added['input']=''
        if kind=='compaction':added['encrypted_content']=''
        result.append(dict(type='response.output_item.added',output_index=index,item=added))
        if kind=='message':
            for part_index,part in enumerate(item['content']):
                result.extend([
                    dict(type='response.content_part.added',item_id=item['id'],output_index=index,content_index=part_index,part={**part,'text':''}),
                    dict(type='response.output_text.delta',item_id=item['id'],output_index=index,content_index=part_index,delta=part['text']),
                    dict(type='response.output_text.done',item_id=item['id'],output_index=index,content_index=part_index,text=part['text']),
                    dict(type='response.content_part.done',item_id=item['id'],output_index=index,content_index=part_index,part=part)])
        result.append(dict(type='response.output_item.done',output_index=index,item=item))
    result.append(dict(type='response.completed',response=response))
    return result


class Server(ThreadingHTTPServer):
    daemon_threads = False
    def __init__(self, address, models):
        super().__init__(address, Handler)
        self.models=set(models);self.capacity=threading.BoundedSemaphore(8)
        self.guard=threading.Lock();self.sockets=set();self.sequence=0;self.epoch=uuid.uuid4().hex
    def process_request(self, request, address):
        if not self.capacity.acquire(False): request.close();return
        with self.guard:self.sockets.add(request)
        try:super().process_request(request,address)
        except BaseException:
            with self.guard:self.sockets.discard(request)
            self.capacity.release();request.close();raise
    def process_request_thread(self, request, address):
        try:super().process_request_thread(request,address)
        finally:
            with self.guard:self.sockets.discard(request)
            self.capacity.release()
    def handle_error(self, *_): pass
    def interrupt(self):
        self.shutdown()
        with self.guard:sockets=list(self.sockets)
        for connection in sockets:
            try:connection.shutdown(socket.SHUT_RDWR)
            except OSError:pass


class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*_):pass
    def handle(self):
        self.connection.settimeout(10)
        try:super().handle()
        except (OSError,ValueError,AssertionError,KeyError):pass
    def events(self,document):
        assert isinstance(document,dict) and document.get('model') in self.server.models
        with self.server.guard:self.server.sequence+=1;index=f'{self.server.epoch}_{self.server.sequence}'
        warmup=document.get('generate') is False
        item=dict(type='message',id=f'msg_trial_{index}',role='assistant',status='completed',
            content=[dict(type='output_text',text=TEXT,annotations=[])])
        response=dict(id=f'resp_trial_{index}',object='response',model=document['model'],status='completed',
            output=[] if warmup else [item],usage=dict(input_tokens=0 if warmup else 1,
            output_tokens=0 if warmup else 1,total_tokens=0 if warmup else 2,input_tokens_details=dict(cached_tokens=0)))
        if any(i.get('type')=='compaction_trigger' for i in document.get('input',[]) if isinstance(i,dict)):
            response['output']=[dict(type='compaction',encrypted_content=f'synthetic-trial-context-{index}')]
        return response_events(response)
    def do_POST(self):
        self.close_connection=True
        try:
            assert self.path in ('/v1/responses','/v1/responses/compact')
            assert self.headers.get('Transfer-Encoding') is None and self.headers.get('Authorization') is None
            assert len(self.headers.get_all('Content-Length',[]))==1
            length=int(self.headers["Content-Length"]);assert 0<length<=8388608
            body=self.rfile.read(length);assert len(body)==length
            document=json.loads(body);events=self.events(document)
            if self.path.endswith('/compact'):
                result=json.dumps(dict(object='response.compaction',output=[dict(type='compaction',encrypted_content='synthetic-trial-compact-'+events[-1]['response']['id'])],usage=dict(input_tokens=1,
                    output_tokens=0,total_tokens=1,input_tokens_details=dict(cached_tokens=0)))).encode();mime='application/json'
            elif document.get('stream'):
                result=''.join('data: '+json.dumps(event)+'\n\n' for event in events).encode();mime='text/event-stream'
            else:result=json.dumps(events[-1]['response']).encode();mime='application/json'
            self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(result)))
            self.end_headers();self.wfile.write(result)
        except (ValueError,AssertionError,KeyError):
            self.send_response(400);self.send_header('Content-Length','0');self.end_headers()
    def do_GET(self):
        self.close_connection=True
        if self.path=='/health/ready':
            result=b'{"synthetic":true}'
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(result)))
            self.end_headers();self.wfile.write(result);return
        self.connection.settimeout(300)
        assert self.path=='/v1/responses' and self.headers.get('Authorization') is None
        key=self.headers['Sec-WebSocket-Key'];accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101);self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade')
        self.send_header('Sec-WebSocket-Accept',accept);self.end_headers()
        while True:
            opcode,body=receive(self.connection,masked=True)
            if opcode==8:return
            if opcode==9:send(self.connection,body,opcode=10);continue
            assert opcode==1
            for event in self.events(json.loads(body)):send(self.connection,event)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,required=True)
    parser.add_argument('--model',action='append',required=True);args=parser.parse_args()
    assert 1<=args.port<=65535 and 1<=len(args.model)<=32 and all(0<len(m.encode())<=128 for m in args.model)
    server=Server(('127.0.0.1',args.port),args.model)
    def shutdown(*_):threading.Thread(target=server.interrupt).start()
    signal.signal(signal.SIGTERM,shutdown);signal.signal(signal.SIGINT,shutdown)
    print('SYNTHETIC_READY',flush=True)
    try:server.serve_forever()
    finally:server.server_close()


if __name__=='__main__':main()
