#!/usr/bin/env python3
"""Private storage observation and bounded Linux tmpfs pressure/ENOSPC; no real accounts."""
import argparse
import errno
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler

import verify_admin
from verify_admin import running_admin, request, document, ADMIN
from verify_keys import create, update
from verify_snapshot_restore import request as generate, ready, stopped
from verify_execution import dispose

MIB=1048576


def observation(f):
    return document(request(f.ports['admin'],'GET','/api/runtime/storage',headers={'Authorization':'Bearer '+ADMIN}))


def until(predicate):
    deadline=time.monotonic()+6
    while True:
        value=predicate()
        if value:return value
        assert time.monotonic()<deadline,'Storage state did not converge'
        time.sleep(0.05)


def fill(file, directory, target):
    block=bytes(MIB)
    while True:
        info=os.statvfs(directory);available=info.f_bavail*info.f_frsize
        if available<=target:break
        try:file.write(block[:min(MIB,available-target)])
        except OSError as error:
            assert error.errno==errno.ENOSPC
            if target>0:raise
            return True
    if target==0:
        try:file.write(block)
        except OSError as error:
            assert error.errno==errno.ENOSPC;return True
    return False


def command(binary,state,*arguments,admin=None,master=None,ok=True):
    environment={'PATH':os.defpath,'CODEXONE_DATA_DIRECTORY':str(state)}
    if admin:environment['CODEXONE_ADMIN_TOKEN_FILE']=str(admin)
    if master:environment['CODEXONE_ACCOUNT_MASTER_KEY_FILE']=str(master)
    result=subprocess.run([binary,*map(str,arguments)],capture_output=True,timeout=30,env=environment)
    assert len(result.stdout+result.stderr)<32768 and str(state.parent).encode() not in result.stdout+result.stderr
    assert (result.returncode==0)==ok,'Offline pressure command returned an unexpected safe state'
    return json.loads(result.stdout) if ok else result


class PressureUpstream(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_POST(self):
        payload=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with self.server.guard:self.server.calls+=1;index=self.server.calls
        response={'id':'synthetic-pressure-'+str(index),'object':'response','status':'completed','model':payload['model'],
                  'output':[{'id':'synthetic-message-'+str(index),'type':'message','role':'assistant',
                             'content':[{'type':'output_text','text':'synthetic','annotations':[]}]}],
                  'usage':{'input_tokens':5,'output_tokens':3,'input_tokens_details':{'cached_tokens':0}}}
        if payload.get('stream'):
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
            self.wfile.write(('data: '+json.dumps({'type':'response.created','response':{**response,'status':'in_progress','output':[],'usage':None}})+'\n\n').encode());self.wfile.flush()
            self.server.held.set();assert self.server.release.wait(timeout=25)
            self.wfile.write(('data: '+json.dumps({'type':'response.completed','response':response})+'\n\ndata: [DONE]\n\n').encode());self.wfile.flush()
        else:
            body=json.dumps(response).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)


def verify(binary,space_root):
    if space_root:
        assert sys.platform=='linux'
        assert subprocess.check_output(['stat','-f','-c','%T',str(space_root)]).strip()==b'tmpfs'
        info=os.statvfs(space_root)
        assert 384*MIB<=info.f_blocks*info.f_frsize<=512*MIB,'Only an explicitly bounded private tmpfs may be filled'
        os.environ['TMPDIR']=str(space_root);tempfile.tempdir=None
        verify_admin.Upstream=PressureUpstream
    with running_admin(binary) as f:
        assert request(f.ports['admin'],'GET','/api/runtime/storage')[0]==401
        sample=observation(f)
        assert sample['pressure']=='normal' and sample['admissionAllowed'] and sample['optionalWorkAllowed']
        assert sample['reserveBytes']==64*MIB and sample['reserveTargetBytes']==64*MIB
        assert sample['peakResidentBytes']>0 and 0<sample['observedFDs']<=sample['fdScanLimit']==1024
        assert str(f.root) not in json.dumps(sample) and 'synthetic' not in json.dumps(sample)
        until(lambda:observation(f)['sampledUnixSeconds']>sample['sampledUnixSeconds'])
        print('PASS: authenticated no-store fixed storage/process/queue observation; periodic owner and private allocated reserve')
        if not space_root:return
        f.provider.held=threading.Event();f.provider.release=threading.Event()
        _,secret=create(f.ports['admin'],principal='synthetic-storage')
        revocable,_=create(f.ports['admin'],principal='synthetic-revocable')
        filler=f.root/'pressure-filler'
        def held():
            f.provider.held.clear();f.provider.release.clear()
            client=http.client.HTTPConnection('127.0.0.1',f.ports['data'],timeout=25)
            client.request('POST','/v1/responses',json.dumps({'model':'synthetic-text','input':'held','stream':True}),headers={'Authorization':'Bearer '+secret,'Content-Type':'application/json'})
            response=client.getresponse();assert response.status==200 and f.provider.held.wait(timeout=5)
            until(lambda:bool(response.fp))
            return client,response
        client,response=held()
        with filler.open('wb',buffering=0) as file:
            fill(file,f.root,200*MIB)
            until(lambda:observation(f)['pressure']=='degraded')
            assert ready(f.ports['admin'])==200
            assert update(f.ports['admin'],revocable,enabled=False)[0]==200
            assert request(f.ports['admin'],'GET','/api/usage/options',headers={'Authorization':'Bearer '+ADMIN})[0]==503
            assert generate(f.ports['data'],secret)[0]==200
            fill(file,f.root,100*MIB)
            until(lambda:observation(f)['pressure']=='blocked')
            assert ready(f.ports['admin'])==503
            assert request(f.ports['admin'],'GET','/health/live')[0]==200
            before=f.provider.calls
            status,body=generate(f.ports['data'],secret)
            assert status==503 and b'storage_pressure' in body and f.provider.calls==before
            f.provider.release.set();assert b'response.completed' in response.read();client.close()
            until(lambda:observation(f)['reserveBytes']<64*MIB)
            assert observation(f)['coreAvailable'] and not observation(f)['admissionAllowed']
        filler.unlink()
        until(lambda:observation(f)['pressure']=='normal')
        assert ready(f.ports['admin'])==200 and generate(f.ports['data'],secret)[0]==200
        client,response=held()
        with filler.open('wb',buffering=0) as file:
            assert fill(file,f.root,0),'No actual ENOSPC observed'
            until(lambda:observation(f)['pressure']=='blocked')
            before=f.provider.calls
            assert generate(f.ports['data'],secret)[0]==503 and f.provider.calls==before
            f.provider.release.set();assert b'response.completed' in response.read();client.close()
            until(lambda:observation(f)['reserveBytes']<64*MIB)
            with sqlite3.connect(f.root/'state/core.sqlite') as db:
                assert not db.execute("SELECT id FROM attempts WHERE state!='settled'").fetchall()
            assert observation(f)['coreAvailable']
        filler.unlink();until(lambda:observation(f)['pressure']=='normal')
        assert ready(f.ports['admin'])==200
        stopped(f.process);f.process=None
        bundle=f.root/'normal-backup'
        command(binary,f.root/'state','--backup',bundle)
        with filler.open('wb',buffering=0) as file:
            fill(file,f.root,100*MIB)
            command(binary,f.root/'state','--backup',f.root/'refused-backup',ok=False)
            assert not (f.root/'refused-backup').exists()
            command(binary,f.root/'refused-restore','--restore',bundle,ok=False)
            assert not (f.root/'refused-restore').exists()
            master=f.root/'synthetic-master';master.write_text('5a'*32);master.chmod(0o600)
            command(binary,f.root/'state','--reencrypt-credentials',f.root/'refused-rekey',admin=f.admin,master=master,ok=False)
            assert not (f.root/'refused-rekey').exists()
            with sqlite3.connect(f.root/'state/core.sqlite') as db:db.execute('PRAGMA user_version=7')
            command(binary,f.root/'state','--migrate',ok=False)
            assert not list((f.root/'state').glob('*.pre-v10-*.sqlite'))
        filler.unlink()
        subprocess.run([binary,'--migrate'],env={'PATH':os.defpath,'CODEXONE_DATA_DIRECTORY':str(f.root/'state')},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
        print('PASS: real bounded tmpfs degraded/blocked/live/ready/no dispatch, actual ENOSPC with reserved in-flight settlement, hysteresis recovery and offline backup/restore/rekey/migration refusal')
    if space_root:interrupted_copy(binary,space_root)


def interrupted_copy(binary,space_root):
    # Public synthetic pages on an ordinary private temp directory; only the bounded target is filled.
    with tempfile.TemporaryDirectory(prefix='codexone-copy-source-',dir='/tmp') as source_tmp, tempfile.TemporaryDirectory(prefix='codexone-copy-target-',dir=space_root) as target_tmp:
        source=Path(source_tmp);source.chmod(0o700);target=Path(target_tmp);target.chmod(0o700)
        probe=str(Path(binary).with_name('ExecutionProbe'))
        seeded=subprocess.run([probe,str(source/'core.sqlite')],input=b'close\n',capture_output=True,timeout=10,env={'PATH':os.defpath});assert seeded.returncode==0
        db=sqlite3.connect(source/'core.sqlite');db.execute('CREATE TABLE synthetic_pages(payload BLOB)');db.execute('INSERT INTO synthetic_pages VALUES(zeroblob(134217728))');db.commit();db.execute('PRAGMA wal_checkpoint(TRUNCATE)');db.close()
        bundle=source/'bundle';command(binary,source,'--backup',bundle)
        digest=hashlib.sha256((bundle/'snapshot.sqlite').read_bytes()).hexdigest()
        state=target/'state';filler=target/'filler'
        process=subprocess.Popen([binary,'--restore',str(bundle)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={'PATH':os.defpath,'CODEXONE_DATA_DIRECTORY':str(state)})
        try:
            until(lambda:(state/'core.sqlite.restore-pending').exists())
            process.send_signal(signal.SIGSTOP)
            with filler.open('wb',buffering=0) as file:fill(file,target,100*MIB)
            process.send_signal(signal.SIGCONT);output,error=process.communicate(timeout=20)
            assert process.returncode!=0 and b'Insufficient storage headroom' in error
            assert not (state/'core.sqlite').exists() and (state/'core.sqlite.restore-pending').exists()
            refused=command(binary,state,'--maintenance-status',ok=False)
            assert b'Incomplete restore target' in refused.stderr
            assert hashlib.sha256((bundle/'snapshot.sqlite').read_bytes()).hexdigest()==digest
        finally:
            if process.poll() is None:process.kill();process.wait(timeout=5)
            process.stdout.close();process.stderr.close()
        print('PASS: actual restore stopped at durable barrier, target space withdrawn, page-budget refusal preserves pending target and original backup')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--binary',type=Path,required=True);parser.add_argument('--space-root',type=Path)
    args=parser.parse_args()
    try:verify(str(args.binary.resolve()),args.space_root)
    except Exception as error:
        trace=error.__traceback__
        while trace.tb_next:trace=trace.tb_next
        location=Path(trace.tb_frame.f_code.co_filename).name+':'+str(trace.tb_lineno)
        print('FAIL: storage pressure verification at '+location+' ('+type(error).__name__+'); private values withheld',file=sys.stderr);raise SystemExit(1)
