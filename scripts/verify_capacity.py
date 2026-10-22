#!/usr/bin/env python3
"""Explicit bounded synthetic capacity rehearsal, separate from routine verification.

The actual runtime and the stimulus share only an isolated loopback namespace;
their cgroups are separate. No Docker socket enters either container.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import secrets
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
import zlib

from verify_websocket import dial, send, receive, exact

MIB = 1048576
MODEL = 'synthetic-host'


def private_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value)); temporary.chmod(0o600)
    temporary.replace(path)


def png_payload():
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    # Valid RGB PNG, ~3MiB, not a user image. Stored DEFLATE keeps the wire envelope large.
    row = b'\0' + bytes(range(256)) * 12
    pixels = row * 1024
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB',1024,1024,8,2,0,0,0))
    return data + chunk(b'IDAT', zlib.compress(pixels, level=0)) + chunk(b'IEND', b'')


def large_send(sock, value):
    data = json.dumps(value).encode()
    assert len(data) <= 8 * MIB
    header = b'\x81' + (bytes([len(data)]) if len(data)<126 else
        b'\x7e'+struct.pack('!H',len(data)) if len(data)<65536 else b'\x7f'+struct.pack('!Q',len(data)))
    sock.sendall(header + data)


def large_receive(sock):
    first, second = exact(sock, 2)
    assert first & 128 and second & 128
    size = second & 127
    if size == 126: size = struct.unpack('!H', exact(sock, 2))[0]
    if size == 127: size = struct.unpack('!Q', exact(sock, 8))[0]
    assert size <= 8*MIB
    mask = exact(sock, 4); payload = exact(sock, size)
    return first & 15, bytes(value ^ mask[index % 4] for index, value in enumerate(payload))


def response(port, path, token, document=None):
    connection = http.client.HTTPConnection('127.0.0.1',port,timeout=15)
    try:
        connection.request('POST' if document is not None else 'GET',path,
            json.dumps(document) if document is not None else None,
            {'Authorization':'Bearer '+token,'Content-Type':'application/json'})
        result = connection.getresponse(); body = result.read(8*MIB+1)
        assert len(body) <= 8*MIB
        return result.status, body
    finally: connection.close()


def vm_snapshot():
    names=('MemTotal','MemAvailable','SwapTotal','SwapFree')
    values={}
    for row in Path('/proc/meminfo').read_text().splitlines():
        key, rest=row.split(':',1)
        if key in names:values[key+'Bytes']=int(rest.split()[0])*1024
    values['loadAverage']=[float(value) for value in Path('/proc/loadavg').read_text().split()[:3]]
    return values


def verify_recovery(observations, now):
    assert all(any(row['phase']==phase for row in observations)
               for phase in ('baseline','sustained','recovery')), 'Missing storage phase evidence'
    recent=[row for row in observations if row['phase']=='recovery' and
            0 <= now-row['sampledUnixSeconds'] <= 5]
    assert len(recent)>=2, 'Recovery storage observations missing or stale'
    assert all(row['coreAvailable'] and row['pressure']=='normal' and
               row['regularQueued']==0 and row['criticalQueued']==0 for row in recent)


def cleanup_owned(identifier, volume, known_ids):
    # The owner exists before the first Engine mutation, including lost CLI results.
    leftovers=run(['docker','ps','-aq','--filter','label=codexone.capacity='+identifier]).stdout.decode().splitlines()
    assert len(leftovers)<=3 and all(re.fullmatch('[0-9a-f]{12,64}',item) for item in leftovers)
    for container in set(leftovers+[item for item in known_ids if item]):
        run(['docker','rm','--force',container],ok=False)
    inspected=run(['docker','volume','inspect',volume],ok=False)
    if inspected.returncode==0:
        owned=json.loads(inspected.stdout)[0]
        assert owned['Labels']['codexone.capacity']==identifier
        run(['docker','volume','rm',volume])
    else:
        # Distinguish absence from an unavailable Engine or another inspect failure.
        present=run(['docker','volume','ls','-q']).stdout.decode().splitlines()
        assert volume not in present, 'Owned volume could not be inspected'


def worker(root, duration, transport):
    os.umask(0o077)
    admin = (root/'admin').read_text(); vm_before=vm_snapshot()
    png = png_payload(); encoded = base64.b64encode(png).decode()
    state = {'calls':0,'active':0,'peakActive':0,'next':0,'duplicates':0}; seen=set()
    lock = threading.Lock(); release = threading.Event(); stop_monitor = threading.Event()
    observations=[]; samples={}; progress={'phase':'starting'}
    def phase(name):
        progress.update(phase=name,unixSeconds=int(time.time()))
        private_json(root/'progress.json',progress)
    class Provider(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*_): pass
        def handle(self):
            try: super().handle()
            except (BrokenPipeError,ConnectionResetError,TimeoutError): pass
        def record(self,request):
            digest=hashlib.sha256(json.dumps({key:value for key,value in request.items() if key!='stream_id'},sort_keys=True).encode()).digest()
            with lock:
                if digest in seen:state['duplicates']+=1
                seen.add(digest);assert len(seen)<=5000
        def events(self, request):
            assert request['model']==MODEL
            self.record(request)
            with lock:
                state['calls']+=1; state['next']+=1; index=state['next']
                state['active']+=1; state['peakActive']=max(state['peakActive'],state['active'])
            try:
                prompt=request.get('input')
                if isinstance(prompt,str) and prompt.startswith('capacity-hold:'): assert release.wait(8)
                warm=request.get('generate') is False
                image=not warm and any(tool.get('type')=='image_generation' for tool in request.get('tools',[]))
                item=({'id':f'ig_{index}','type':'image_generation_call','status':'completed','result':encoded,
                       'usage':{'input_tokens':2,'output_tokens':3,'total_tokens':5}}
                    if image else {'id':f'msg_{index}','type':'message','role':'assistant',
                       'content':[{'type':'output_text','text':'synthetic capacity output '*256,'annotations':[]}]})
                payload={'id':f'resp_{index}','status':'completed','output':[] if warm else [item],
                         'usage':{'input_tokens':0 if warm else 5,'output_tokens':0 if warm else 7,'input_tokens_details':{'cached_tokens':0}}}
                lane={'stream_id':request['stream_id']} if 'stream_id' in request else {}
                events=[{'type':'response.created','response':{**payload,'status':'in_progress','output':[],'usage':None},**lane}]
                if isinstance(prompt,str) and prompt.startswith('capacity-abrupt:'): return events
                if not warm:
                    added={**item,'status':'in_progress'}
                    if image: added['result']=None
                    events += [{'type':'response.output_item.added','item':added,**lane},
                               {'type':'response.output_item.done','item':item,**lane}]
                return events+[{'type':'response.completed','response':payload,**lane}]
            finally:
                with lock: state['active']-=1
        def do_POST(self):
            length=int(self.headers.get('Content-Length','0')); assert 0<length<=8*MIB
            assert self.headers.get('Authorization') is None
            request=json.loads(self.rfile.read(length))
            if self.path=='/v1/responses/compact':
                self.record(request)
                with lock: state['calls']+=1;state['next']+=1; index=state['next']
                payload={'id':f'cmp_{index}','object':'response.compaction','created_at':1,
                         'output':[{'type':'compaction','id':f'ci_{index}','encrypted_content':f'synthetic-capacity-context-{index}'}],
                         'usage':{'input_tokens':5,'output_tokens':3,'input_tokens_details':{'cached_tokens':0}}}
                body=json.dumps(payload).encode(); streaming=False
            else:
                assert self.path=='/v1/responses'
                events=self.events(request); streaming=request.get('stream',False)
                body=(''.join('data: '+json.dumps(event)+'\n\n' for event in events).encode()
                      if streaming else json.dumps(events[-1]['response']).encode())
            self.send_response(200)
            self.send_header('Content-Type','text/event-stream' if streaming else 'application/json')
            self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def do_GET(self):
            assert self.path=='/v1/responses' and self.headers.get('Authorization') is None
            accept=base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101);self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade')
            self.send_header('Sec-WebSocket-Accept',accept);self.end_headers()
            try:
                while True:
                    opcode,data=large_receive(self.connection)
                    if opcode==8:return
                    for event in self.events(json.loads(data)): large_send(self.connection,event)
            except (EOFError,OSError): pass
    provider=ThreadingHTTPServer(('127.0.0.1',19090),Provider);provider.daemon_threads=True
    owner=threading.Thread(target=provider.serve_forever);owner.start()
    try:
        deadline=time.monotonic()+40
        while time.monotonic()<deadline:
            try:
                if response(18081,'/health/live',admin)[0]==200:break
            except OSError: pass
            time.sleep(0.2)
        else:raise AssertionError('Gateway startup deadline')
        keys=[]
        for index in range(5):
            status,body=response(18081,'/api/keys',admin,{'principal':('synthetic-capacity-disconnect' if index==4 else f'synthetic-capacity-{index}'),
                'models':[MODEL],'visionInput':True,'imageGeneration':True,'imageModels':['synthetic-image'],
                'limits':{'requests':5000,'active':8,'unresolved':8,'budgetMicros':1000000,'unresolvedMicros':1000000}})
            assert status==201
            keys.append(json.loads(body)['secret'])
        abrupt_key=keys.pop()
        def monitor():
            while not stop_monitor.is_set():
                try:
                    status,body=response(18081,'/api/runtime/storage',admin)
                    if status==200 and len(observations)<2000:
                        observations.append({'phase':progress['phase'],**json.loads(body)})
                except (OSError,http.client.HTTPException):pass
                stop_monitor.wait(1)
        monitor_thread=threading.Thread(target=monitor);monitor_thread.start()
        def operation(kind,index):
            nonce=secrets.token_hex(12)
            started=time.monotonic(); token=abrupt_key if kind=='abrupt' else keys[index%len(keys)]; status=0; bytes_read=0; failure=None
            try:
                if kind in ('ws','warmup'):
                    with dial(18080,token=token) as sock:
                        create={'type':'response.create','model':MODEL,'input':'synthetic-capacity:'+nonce}
                        if kind=='warmup':create['generate']=False
                        send(sock,create,masked=True)
                        while True:
                            opcode,body=receive(sock);assert opcode==1
                            event=json.loads(body);bytes_read+=len(body)
                            if event['type']=='error': status=503;break
                            if event['type']=='response.completed':status=200;break
                        send(sock,b'',masked=True,opcode=8)
                else:
                    path='/v1/responses'; document={'model':MODEL,'input':'synthetic-capacity:'+nonce,'stream':kind=='sse'}
                    if kind=='compact':path+='/compact';document={'model':MODEL,'input':[{'role':'user','content':'synthetic retained:'+nonce}]}
                    if kind in ('image','edit'):
                        path='/v1/images/'+('generations' if kind=='image' else 'edits')
                        document={'prompt':'synthetic capacity:'+nonce,'model':'synthetic-image'}
                        if kind=='edit':document['images']=[{'image_url':'data:image/png;base64,'+encoded}]
                    if kind in ('abrupt','hold'):document.update(input=('capacity-abrupt:' if kind=='abrupt' else 'capacity-hold:')+nonce,stream=True)
                    status,body=response(18080,path,token,document);bytes_read=len(body)
                    if status!=200 and len(body)<16384:
                        try:
                            code=json.loads(body).get('error',{}).get('code')
                            if isinstance(code,str) and len(code)<=64 and all(character in 'abcdefghijklmnopqrstuvwxyz_' for character in code):failure=code
                        except (ValueError,AttributeError):pass
                    if status==200:
                        if kind in ('image','edit'):assert json.loads(body)['data'][0]['b64_json']==encoded
                        elif kind=='sse':assert b'response.completed' in body
                        elif kind=='abrupt':assert b'response.completed' not in body
                        elif kind=='compact':assert json.loads(body)['object']=='response.compaction'
                        elif kind=='json':assert json.loads(body)['status']=='completed'
                        elif kind=='hold':assert b'response.completed' in body
            except (OSError,http.client.HTTPException,EOFError) as error:
                status=0; failure=type(error).__name__
            return {'kind':kind,'status':status,'seconds':time.monotonic()-started,'bytes':bytes_read,'failure':failure}
        results=[]
        phase('baseline');time.sleep(4)
        kinds=['json','sse','compact','image','edit']
        if transport=='websocket': kinds += ['ws','warmup']
        phase('coverage')
        for index,kind in enumerate(kinds):
            phase('coverage-'+kind)
            item=operation(kind,index);results.append(item)
            if item['status']!=200:print('FAIL: coverage '+kind+' status='+str(item['status']),flush=True)
            assert item['status']==200, 'Coverage operation rejected'
        phase('overload')
        before=state['calls']; release.clear()
        with ThreadPoolExecutor(max_workers=24) as executor:
            pending=[executor.submit(operation,'hold',index) for index in range(24)]
            time.sleep(2);release.set()
            batch=[future.result(timeout=15) for future in pending]
        print('PROBE: overload successes='+str(sum(item['status']==200 for item in batch))+' calls='+str(state['calls']-before)+' peak='+str(state['peakActive']),flush=True)
        assert sum(item['status']!=200 for item in batch)>=16
        assert state['calls']-before<=8
        assert all(item['seconds']<15 for item in batch)
        results.extend(batch)
        phase('disconnect')
        for index in range(2):
            item=operation('abrupt',index);results.append(item);assert item['status']==200
        phase('sustained');started=time.monotonic();end=started+duration;next_send=started;index=0;skipped=0
        with ThreadPoolExecutor(max_workers=4) as executor:
            pending=set()
            while time.monotonic()<end or pending:
                now=time.monotonic()
                if now<end and now>=next_send:
                    if len(pending)<4:
                        # Image payload is deliberate, but not every request is a multi-MiB image.
                        kind=kinds[index%len(kinds)]
                        pending.add(executor.submit(operation,kind,index));index+=1
                    else:skipped+=1
                    next_send=now+0.25
                if pending:
                    completed,pending=wait(pending,timeout=0.05,return_when=FIRST_COMPLETED)
                else:
                    time.sleep(min(0.05,max(0.001,next_send-time.monotonic())))
                    completed=set()
                for future in completed:results.append(future.result())
                if index and index%40==0:
                    progress.update(submitted=index,skipped=skipped)
                    private_json(root/'progress.json',progress)
        sustained_elapsed=time.monotonic()-started
        phase('recovery');time.sleep(12)
        stop_monitor.set();monitor_thread.join(timeout=16);assert not monitor_thread.is_alive()
        verify_recovery(observations, time.time())
        normal=[item for item in results if item['kind']!='hold']
        for item in normal:
            if item['status']!=200:print('FAIL: mixed '+item['kind']+' status='+str(item['status'])+' class='+str(item['failure'])+' seconds='+str(round(item['seconds'],2)),flush=True)
        assert all(item['status']==200 for item in normal), 'Normal envelope had unexpected rejection'
        for kind in kinds+['abrupt','hold']:
            rows=[item for item in results if item['kind']==kind]
            latencies=sorted(item['seconds'] for item in rows)
            samples[kind]={'requests':len(rows),'statuses':{str(code):sum(row['status']==code for row in rows) for code in set(row['status'] for row in rows)},
                           'p50Seconds':latencies[len(latencies)//2], 'p95Seconds':latencies[min(len(latencies)-1,int(len(latencies)*0.95))],
                           'maximumSeconds':max(latencies),'responseBytes':sum(row['bytes'] for row in rows)}
        assert state['duplicates']==0, 'Provider saw a replayed synthetic invocation'
        report={'transport':transport,'durationSeconds':duration,'offeredRPS':4,'maximumStimulusInFlight':4,
            'submittedSustained':index,'skippedStimulusSlots':skipped,'imageBytes':len(png),
            'completedSustainedRPS':index/sustained_elapsed,'actualSustainedSeconds':sustained_elapsed,
            'enabledOperations':kinds,'vmBefore':vm_before,'vmAfter':vm_snapshot(),'providerCalls':state['calls'],'providerPeakConcurrentEventConstruction':state['peakActive'],'operations':samples,
            'storage':observations,'expectedDisconnects':2,'providerReplayDetections':state['duplicates']}
        text=json.dumps(report)
        assert admin not in text and all(key not in text for key in keys+[abrupt_key]) and encoded[:64] not in text
        private_json(root/'worker-result.json',report)
        phase('complete')
        print('PASS: bounded synthetic mixed load, overload rejection, disconnect and recovery',flush=True)
    finally:
        release.set();stop_monitor.set()
        if 'monitor_thread' in locals():monitor_thread.join(timeout=16)
        provider.shutdown();provider.server_close();owner.join(timeout=3)
        assert not owner.is_alive()


def run(command,ok=True,timeout=35):
    result=subprocess.run(command,capture_output=True,timeout=timeout)
    if ok:assert result.returncode==0,'Capacity command failed; private diagnostics withheld'
    return result


def config_document(transport):
    return {'managedKeys':True,'namespace':'synthetic-capacity','identity':'synthetic-capacity',
        'reservedMicros':1,'executionTimeoutSeconds':10,'upstreamTransport':transport,
        'upstreamBaseURL':'http://127.0.0.1:19090/v1',
        'models':[{'id':MODEL,'visionInput':True,'imageGeneration':True,'inputMicrosPerMillion':0,'outputMicrosPerMillion':0,
                   'catalog':{'baseInstructions':'Explicit synthetic capacity profile'}}],
        'imageGeneration':{'defaultModel':'synthetic-image','models':[{'id':'synthetic-image','hostModel':MODEL,
            'sizePolicy':'fixed1536','supportsTransparency':True,'supportsInputFidelity':True,
            'inputMicrosPerMillion':0,'outputMicrosPerMillion':0}]}}


def resources(container):
    script="""awk '/^VmRSS:/{print $2}' /proc/1/status
cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.peak
find /proc/1/fd -mindepth 1 -maxdepth 1 | wc -l
find /proc/1/task -mindepth 1 -maxdepth 1 | wc -l
cat /sys/fs/cgroup/memory.swap.max
cat /sys/fs/cgroup/memory.events
awk '{print "cpu." $1 " " $2}' /sys/fs/cgroup/cpu.stat
"""
    raw=run(['docker','exec',container,'sh','-ec',script]).stdout.decode().splitlines()
    assert len(raw)>=7
    counters=dict((key,int(value)) for key,value in (row.split() for row in raw[6:]))
    return {'rssBytes':int(raw[0])*1024,'cgroupCurrentBytes':int(raw[1]),'cgroupPeakBytes':int(raw[2]),
            'fds':int(raw[3]),'threads':int(raw[4]),'swapMaximumBytes':int(raw[5]),
            'memoryEvents':{key:value for key,value in counters.items() if not key.startswith('cpu.')},
            'cpu':{key[4:]:value for key,value in counters.items() if key.startswith('cpu.')}}


def orchestrate(args):
    output=args.output.resolve();assert not output.exists(),'Refuse overwriting previous capacity evidence'
    runtime=json.loads(run(['docker','image','inspect',args.image]).stdout)[0]
    harness=json.loads(run(['docker','image','inspect',args.harness_image]).stdout)[0]
    assert runtime['Architecture']==harness['Architecture']=='amd64'
    assert runtime['Os']==harness['Os']=='linux'
    info=json.loads(run(['docker','info','--format','{{json .}}']).stdout)
    existing=len(run(['docker','ps','-q']).stdout.decode().splitlines())
    reports=[]
    uid=os.getuid() or 10001;gid=os.getgid() if os.getuid() else 10001
    previous=os.umask(0o077)
    try:
        for transport in (('http','websocket') if args.transport=='both' else (args.transport,)):
            identifier=uuid.uuid4().hex; volume='codexone-capacity-'+identifier
            worker_id=gateway_id=None
            with tempfile.TemporaryDirectory(prefix='codexone-capacity-') as temporary:
                root=Path(temporary)
                (root/'admin').write_text(secrets.token_urlsafe(48));(root/'admin').chmod(0o600)
                private_json(root/'identity.json',config_document(transport))
                if os.getuid()==0:
                    for file in root.iterdir():os.chown(file,uid,gid)
                    os.chown(root,uid,gid)
                try:
                    run(['docker','volume','create','--label','codexone.capacity='+identifier,volume])
                    run(['docker','run','--rm','--platform','linux/amd64','--network','none','--read-only','--user','0:0',
                        '--label','codexone.capacity='+identifier,'--memory','64m','--memory-swap','64m','--cpus','1','--pids-limit','16',
                        '--cap-drop','ALL','--cap-add','CHOWN','--cap-add','FOWNER','--cap-add','DAC_OVERRIDE','--security-opt','no-new-privileges:true',
                        '--mount',f'type=volume,src={volume},dst=/var/lib/codexone,volume-nocopy','--entrypoint','sh',runtime['Id'],
                        '-ec',f'test -z "$(find /var/lib/codexone -mindepth 1 -maxdepth 1 -print -quit)"; chown {uid}:{gid} /var/lib/codexone; chmod 700 /var/lib/codexone'])
                    worker_id=run(['docker','run','-d','--platform','linux/amd64','--network','none','--read-only','--user',f'{uid}:{gid}',
                        '--cap-drop','ALL','--security-opt','no-new-privileges:true','--memory','512m','--memory-swap','512m','--cpus','1','--pids-limit','128','--label','codexone.capacity='+identifier,
                        '--tmpfs','/tmp:rw,nosuid,size=64m,mode=1777','--env','PYTHONDONTWRITEBYTECODE=1',
                        '--mount',f'type=bind,src={root},dst=/run/capacity',
                        '--mount',f'type=bind,src={Path(__file__).resolve().parent},dst=/test/scripts,readonly',
                        '--entrypoint','python3',harness['Id'],'/test/scripts/verify_capacity.py','--worker','--root','/run/capacity',
                        '--duration',str(args.duration),'--transport',transport]).stdout.decode().strip()
                    gateway_id=run(['docker','run','-d','--platform','linux/amd64','--network','container:'+worker_id,'--read-only','--user',f'{uid}:{gid}',
                        '--cap-drop','ALL','--security-opt','no-new-privileges:true','--memory','768m','--memory-swap','768m','--cpus','1','--pids-limit','128','--label','codexone.capacity='+identifier,
                        '--tmpfs','/tmp:rw,noexec,nosuid,size=16m,mode=1777',
                        '--mount',f'type=bind,src={root},dst=/run/capacity,readonly',
                        '--mount',f'type=volume,src={volume},dst=/var/lib/codexone,volume-nocopy',
                        '--env','CODEXONE_IDENTITY_CONFIG=/run/capacity/identity.json',
                        '--env','CODEXONE_ADMIN_TOKEN_FILE=/run/capacity/admin',runtime['Id']]).stdout.decode().strip()
                    installed=json.loads(run(['docker','inspect',gateway_id]).stdout)[0]
                    limits=installed['HostConfig']; mounts={item['Destination']:item for item in installed['Mounts']}
                    assert limits['Memory']==768*MIB and limits['MemorySwap']==768*MIB
                    assert limits['NanoCpus']==1000000000 and limits['PidsLimit']==128
                    assert limits['ReadonlyRootfs'] and 'ALL' in limits['CapDrop']
                    assert mounts['/var/lib/codexone']['Type']=='volume' and not mounts['/run/capacity']['RW']
                    filesystem=run(['docker','exec',gateway_id,'stat','-f','-c','%T','/var/lib/codexone']).stdout.decode().strip()
                    started=time.monotonic(); series=[]
                    while True:
                        state=json.loads(run(['docker','inspect',worker_id]).stdout)[0]['State']
                        if not state['Running']:
                            assert state['ExitCode']==0,'Stimulus failed; private diagnostics withheld'
                            break
                        assert time.monotonic()-started<args.duration+150,'Capacity owner exceeded deadline'
                        metric=resources(gateway_id)
                        progress=json.loads((root/'progress.json').read_text()) if (root/'progress.json').exists() else {'phase':'starting'}
                        series.append({'elapsedSeconds':round(time.monotonic()-started,2),'phase':progress['phase'],**metric})
                        if len(series)%15==0:print('PROGRESS: '+transport+' '+progress['phase']+' samples='+str(len(series)),flush=True)
                        time.sleep(2)
                    report=json.loads((root/'worker-result.json').read_text())
                    rows=json.loads(run(['docker','exec',gateway_id,'sqlite3','-readonly','-json','/var/lib/codexone/core.sqlite',
                        'SELECT state,COUNT(*) AS count,SUM(reserved) AS reserved FROM attempts GROUP BY state;']).stdout)
                    counts={row['state']:row['count'] for row in rows}
                    assert counts.get('intent',0)==0 and counts.get('unknown',0)==2
                    assert sum(counts.values())==report['providerCalls']
                    assert next(row['reserved'] for row in rows if row['state']=='unknown')==2
                    ownership=json.loads(run(['docker','exec',gateway_id,'sqlite3','-readonly','-json','/var/lib/codexone/core.sqlite',
                        "SELECT principal,state,COUNT(*) AS count,SUM(reserved) AS reserved, "
                        "SUM((SELECT COUNT(*) FROM evidence e WHERE e.attempt=a.id AND json_extract(e.payload,'$.completeness')='complete')) AS completeEvidence "
                        "FROM attempts a GROUP BY principal,state;"]).stdout)
                    interrupted=[row for row in ownership if row['principal']=='synthetic-capacity-disconnect']
                    assert len(interrupted)==1 and interrupted[0]['state']=='unknown'
                    assert interrupted[0]['count']==2 and interrupted[0]['reserved']==2 and interrupted[0]['completeEvidence']==0
                    ordinary=[row for row in ownership if row['principal']!='synthetic-capacity-disconnect']
                    assert ordinary and all(row['state']=='settled' for row in ordinary)
                    expected=sum(item['statuses'].get('200',0) for kind,item in report['operations'].items() if kind!='abrupt')
                    assert sum(row['count'] for row in ordinary)==expected
                    recovery=[row for row in series if row['phase']=='recovery'];baseline=[row for row in series if row['phase']=='baseline']
                    assert len(recovery)>=3 and baseline
                    assert recovery[-1]['fds']<=max(row['fds'] for row in baseline)+8
                    assert recovery[-1]['rssBytes']<768*MIB*0.7
                    assert all(row['memoryEvents'].get('oom_kill',0)==0 and row['swapMaximumBytes']==0 for row in series)
                    run(['docker','stop','--time','30',gateway_id],timeout=40)
                    state=json.loads(run(['docker','inspect',gateway_id]).stdout)[0]['State']
                    assert state['ExitCode']==0 and not state['OOMKilled']
                    captured=run(['docker','logs',gateway_id]);logs=captured.stdout+captured.stderr
                    assert len(logs)<262144
                    assert (root/'admin').read_bytes() not in logs and str(root).encode() not in logs
                    assert b'synthetic-capacity:' not in logs and b'iVBORw0KGgo' not in logs
                    assert re.search(rb'(?:co1_|as1_|ac1_)[A-Za-z0-9_-]{43}',logs) is None
                    report.update(runtimeLogsChecked=True,ledgerOwnership=ownership,resources=series,dataFilesystem=filesystem,ledger=rows,runtimeExitCode=state['ExitCode'],runtimeOOMKilled=state['OOMKilled'])
                    reports.append(report)
                    print('PASS: '+transport+' bounded profile and preserved responsibility',flush=True)
                except Exception:
                    if worker_id:
                        captured=run(['docker','logs',worker_id],ok=False)
                        logs=(captured.stdout+captured.stderr).decode(errors='replace')
                        if (root/'progress.json').exists():
                            print('FAIL: capacity phase='+json.loads((root/'progress.json').read_text())['phase'],flush=True)
                        for line in logs.splitlines():
                            if line.startswith(('FAIL: capacity ','FAIL: coverage ','FAIL: mixed ','PROBE: overload ')):
                                print(line,flush=True)
                    raise
                finally:
                    cleanup_owned(identifier,volume,(gateway_id,worker_id))
        document={'runtimeImageID':runtime['Id'],'sourceRevision':runtime['Config']['Labels']['org.opencontainers.image.revision'],
            'harnessImageID':harness['Id'],'harnessSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'websocketHelperSHA256':hashlib.sha256(Path(__file__).with_name('verify_websocket.py').read_bytes()).hexdigest(),'platform':{'imageArchitecture':'amd64','engineArchitecture':info['Architecture'],
            'engineCPUs':info['NCPU'],'engineMemoryBytes':info['MemTotal'],'coResidentContainersAtStart':existing},
            'gatewayLimits':{'memoryBytes':768*MIB,'cpuQuota':1,'pids':128,'swapAllowed':False,'data':'Linux local volume'},
            'stimulusLimits':{'memoryBytes':512*MIB,'cpuQuota':1,'maximumSustainedInFlight':4},
            'gaps':['1.6GiB reference host equivalence','real subscription/Desktop','M5 cache','async task tracing','real old-service load'],
            'coResidentContainersAtEnd':len(run(['docker','ps','-q']).stdout.decode().splitlines()),'profiles':reports}
        text=json.dumps(document,indent=2)
        assert 'co1_' not in text and ('/'+'Users'+'/') not in text
        output.mkdir(parents=True,mode=0o700)
        (output/'report.json').write_text(text+'\n')
        print('PASS: sanitized capacity report; target-host and cache gaps retained',flush=True)
    finally:os.umask(previous)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker',action='store_true');parser.add_argument('--root',type=Path)
    parser.add_argument('--image');parser.add_argument('--harness-image',default='codexone:v8-verification')
    parser.add_argument('--output',type=Path);parser.add_argument('--duration',type=int,default=600)
    parser.add_argument('--transport',choices=('http','websocket','both'),default='both')
    args=parser.parse_args();assert 10<=args.duration<=900
    if args.worker:
        assert args.root and args.transport!='both';worker(args.root,args.duration,args.transport)
    else:
        assert args.image and args.output;orchestrate(args)


if __name__=='__main__':
    try:main()
    except Exception as error:
        frames=traceback.extract_tb(error.__traceback__)
        print('FAIL: capacity '+type(error).__name__+' at '+','.join(Path(frame.filename).name+':'+str(frame.lineno) for frame in frames[-4:]),file=sys.stderr)
        sys.exit(1)
