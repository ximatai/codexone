#!/usr/bin/env python3
"""Observation-only synthetic protocol audit; never contacts a real provider."""
import argparse,base64,hashlib,json,sqlite3,sys,tempfile,threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
sys.path.insert(0,str(Path(__file__).resolve().parents[3]/'scripts'))
parser=argparse.ArgumentParser()
parser.add_argument('--binary',type=Path,required=True)
cases=['normal','id-switch','item-switch','status-mismatch','failed-with-error','failed-no-error','missing-usage','negative-total','error-first']
parser.add_argument('--case',choices=cases)
parser.add_argument('--transport',choices=['http','bridge','native'])
args=parser.parse_args()
binary=str(args.binary.resolve())
selected_cases=[args.case] if args.case else cases
transports=[args.transport] if args.transport else ['http','bridge','native']
from verify_protocol import TOKEN,connect,start,stop
from verify_websocket import dial,send,receive

class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args): pass
 def events(self,doc):
  mode=doc['input'];self.server.calls+=1
  usage=dict(input_tokens=2,output_tokens=1,total_tokens=3,input_tokens_details=dict(cached_tokens=0))
  item=dict(type='message',id='msg_a',role='assistant',status='completed',content=[dict(type='output_text',text='synthetic A',annotations=[])])
  final=dict(id='resp_a',object='response',model='synthetic-text',status='completed',output=[item],usage=usage)
  created=dict(type='response.created',response={**final,'status':'in_progress','output':[],'usage':None})
  added=dict(type='response.output_item.added',output_index=0,item={**item,'status':'in_progress','content':[]})
  done=dict(type='response.output_item.done',output_index=0,item=item)
  kind='response.completed'
  if mode=='id-switch': final={**final,'id':'resp_b'}
  if mode=='item-switch': final={**final,'output':[{**item,'id':'msg_b','content':[dict(type='output_text',text='synthetic B',annotations=[])]}]}
  if mode=='status-mismatch': final={**final,'status':'failed'}
  if mode=='failed-with-error':
   kind='response.failed';final={**final,'status':'failed','error':dict(code='rate_limit_exceeded',message='synthetic withheld detail')}
  if mode=='failed-no-error':kind='response.failed';final={**final,'status':'failed'}
  if mode=='missing-usage':final={**final,'usage':None}
  if mode=='negative-total':final={**final,'usage':{**usage,'total_tokens':-1}}
  if mode=='error-first':return [dict(type='error',status=429,error=dict(type='rate_limit_error',code='rate_limit_exceeded',message='synthetic withheld detail'))]
  return [created,added,done,dict(type=kind,response=final)]
 def do_POST(self):
  body=self.rfile.read(int(self.headers['Content-Length']));doc=json.loads(body)
  events=self.events(doc)
  if doc.get('stream'):
   out=''.join('data: '+json.dumps(x)+'\n\n' for x in events).encode();mime='text/event-stream'
  else:out=json.dumps(events[-1].get('response',events[-1])).encode();mime='application/json'
  self.close_connection=True
  self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(out)));self.end_headers();self.wfile.write(out)
 def do_GET(self):
  self.close_connection=True;self.connection.settimeout(8)
  key=self.headers['Sec-WebSocket-Key'];accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
  self.send_response(101);self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade');self.send_header('Sec-WebSocket-Accept',accept);self.end_headers()
  try:
   op,body=receive(self.connection,masked=True)
   for e in self.events(json.loads(body)):send(self.connection,e)
   while self.connection.recv(1024):pass
  except (OSError,EOFError,ValueError):pass

server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.calls=0;server.daemon_threads=True
thread=threading.Thread(target=server.serve_forever);thread.start()
rows=[]
try:
 for transport in transports:
  for mode in selected_cases:
   with tempfile.TemporaryDirectory(prefix='codexone-audit-') as tmp:
    root=Path(tmp);cfg=root/'identity.json'
    cfg.write_text(json.dumps(dict(principal='synthetic-principal',keyID='synthetic-key',namespace='synthetic-audit',identity='synthetic-upstream',keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),reservedMicros=1,models=[dict(id='synthetic-text',inputMicrosPerMillion=1000000,outputMicrosPerMillion=1000000)],upstreamTransport='http' if transport=='http' else 'websocket',upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1')));cfg.chmod(0o600)
    proc,ports=start(binary,cfg,root)
    before=server.calls
    try:
     doc=dict(model='synthetic-text',input=mode,stream=True)
     if transport=='native':
      status=101;events=[]
      with dial(ports['data']) as sock:
       send(sock,{**doc,'type':'response.create'},masked=True)
       while len(events)<12:
        try:op,raw=receive(sock)
        except (OSError,EOFError):break
        if op!=1:break
        e=json.loads(raw);events.append(e)
        if e['type'] in ['response.completed','response.failed','response.incomplete','error']:break
     else:
      status,raw=connect(ports['data'],'POST','/v1/responses',doc)
      events=[]
      for line in raw.splitlines():
       if line.startswith(b'data: ') and line[6:]!=b'[DONE]':
        try:events.append(json.loads(line[6:]))
        except ValueError:pass
      if not events and status!=200:
       try:events.append(json.loads(raw))
       except ValueError:pass
     result=dict(transport=transport,case=mode,status=status,events=[x.get('type','http-error') for x in events],errors=[x.get('error',{}).get('code') for x in events if x.get('error')],calls=server.calls-before,terminalStatuses=[x['response'].get('status') for x in events if x.get('type') in ['response.completed','response.failed']])
    finally:stop(proc)
    with sqlite3.connect(root/'state/core.sqlite') as db:
     state,usage,outcome=db.execute('SELECT state,usage_json,outcome_json FROM attempts ORDER BY rowid DESC LIMIT 1').fetchone()
     result.update(ledger=state,complete=json.loads(usage)['completeness'] if usage else None,failure=json.loads(outcome).get('failure') if outcome else None)
    rows.append(result);print(json.dumps(result),flush=True)
finally:
 server.shutdown();server.server_close();thread.join(5)
assert not thread.is_alive()
assert len(rows)==len(transports)*len(selected_cases) and all(row['calls']==1 for row in rows)
print(json.dumps(dict(observations=len(rows),upstreamCalls=sum(row['calls'] for row in rows))),flush=True)
