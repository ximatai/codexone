#!/usr/bin/env python3
"""Offline digest staging and actual HTTP/WS activation, without existing services or real keys."""
import argparse
import copy
import hashlib
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
import time
from verify_keys import ADMIN, LIMITS, call, update
from verify_protocol import Upstream, start, stop, latest
from verify_websocket import Provider, dial, turn

SECRET = 'sk-synthetic-import-key-000000000000000001'
OTHER = 'sk-synthetic-import-key-000000000000000002'


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    binary=str(parser.parse_args().binary.resolve())
    with tempfile.TemporaryDirectory(prefix='codexone-key-import-') as temporary:
        root=Path(temporary); admin=root/'admin';admin.write_text(ADMIN);admin.chmod(0o600)
        policy=dict(models=['synthetic-text'],limits={**LIMITS,'requests':2})
        entries=[dict(id='import-'+str(n),principal='import-principal-'+str(n),
            digest=hashlib.sha256(secret.encode()).hexdigest(),policy=copy.deepcopy(policy),
            sourceActive=True,sourceExpiresAtUnixSeconds=None,policyEquivalent=True)
            for n,secret in enumerate((SECRET,OTHER))]
        entries[1]['policy'].update(limits=dict.fromkeys(LIMITS),models=None,imageGeneration=True,imageModels=None)
        manifest=dict(version=1,capturedAtUnixSeconds=int(time.time()),entries=entries)
        def invoke(directory,value,*,file_mode=0o600,link=False,raw=None):
            directory.mkdir(exist_ok=True)
            path=directory/'import.json';path.write_text(raw if raw is not None else json.dumps(value));path.chmod(file_mode)
            source=path
            if link:
                source=directory/'link.json';source.symlink_to(path)
            result=subprocess.run([binary,'--import-keys',str(source)],env=dict(PATH=os.defpath,
                CODEXONE_DATA_DIRECTORY=str(directory/'state'),CODEXONE_ADMIN_TOKEN_FILE=str(admin)),
                capture_output=True,timeout=15)
            for private in (SECRET,OTHER,ADMIN,str(root),entries[0]['digest'],entries[1]['digest']):
                assert private.encode() not in result.stdout+result.stderr,'Private import material leaked'
            return result
        bad=[]
        for field,value in [('digest','g'*64),('id','bad/path'),('sourceActive',False),
                            ('sourceExpiresAtUnixSeconds',4102444800),('policyEquivalent',False),
                            ('secret',SECRET)]:
            v=copy.deepcopy(manifest);v['entries'][1][field]=value;bad.append(v)
        for field in ('id','digest'):
            v=copy.deepcopy(manifest);v['entries'][1][field]=v['entries'][0][field];bad.append(v)
        v=copy.deepcopy(manifest);v['entries'][0]['digest']=hashlib.sha256(ADMIN.encode()).hexdigest();bad.append(v)
        v=copy.deepcopy(manifest);v['entries'][0]['policy']['limits']['unexpected']=1;bad.append(v)
        v=copy.deepcopy(manifest);v['version']=2;bad.append(v)
        v=copy.deepcopy(manifest);v['entries']=v['entries']*129;bad.append(v)
        v=copy.deepcopy(manifest);v['unexpected']=True;bad.append(v)
        for captured in (1,4102444800):
            v=copy.deepcopy(manifest);v['capturedAtUnixSeconds']=captured;bad.append(v)
        for field in LIMITS:
            for invalid in (-1,0,10**12+1,'invalid'):
                v=copy.deepcopy(manifest);v['entries'][1]['policy']['limits'][field]=invalid;bad.append(v)
            v=copy.deepcopy(manifest);del v['entries'][1]['policy']['limits'][field];bad.append(v)
        v=copy.deepcopy(manifest);del v['entries'][0]['policy']['models'];bad.append(v)
        for n,value in enumerate(bad):
            directory=root/f'bad-{n}';assert invoke(directory,value).returncode!=0
            assert not (directory/'state').exists(),'Invalid manifest created storage'
        for name,options in [('permissions',dict(file_mode=0o644)),('link',dict(link=True)),
                             ('oversized',dict(raw=' '*1048577))]:
            directory=root/name;assert invoke(directory,manifest,**options).returncode!=0
            assert not (directory/'state').exists()
        target=root/'valid';result=invoke(target,manifest);assert result.returncode==0
        assert json.loads(result.stdout)==dict(importedKeys=2,enabledKeys=0)
        dbpath=target/'state/core.sqlite'
        with sqlite3.connect(dbpath) as db:
            assert db.execute('SELECT COUNT(*) FROM key_events WHERE action="import_disabled"').fetchone()[0]==2
            assert all(not json.loads(r[0])['enabled'] for r in db.execute('SELECT metadata_json FROM managed_keys'))
        assert invoke(target,manifest).returncode!=0,'Import replay replaced an existing target'
        provider=ThreadingHTTPServer(('127.0.0.1',0),Provider);provider.daemon_threads=True;provider.calls=provider.connections=0
        provider.stalled=threading.Event();provider.cancelled=threading.Event()
        provider.guard=threading.Lock();thread=threading.Thread(target=provider.serve_forever);thread.start()
        try:
            config=target/'identity.json';config.write_text(json.dumps(dict(managedKeys=True,
                namespace='synthetic-import',identity='synthetic-provider',reservedMicros=1,upstreamTransport='websocket',
                models=[dict(id='synthetic-text',inputMicrosPerMillion=1,outputMicrosPerMillion=1)],
                upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1')));config.chmod(0o600)
            gateway,ports=start(binary,config,target,admin_token_file=admin)
            try:
                assert invoke(target,manifest).returncode!=0,'Import bypassed the instance lock'
                assert call(ports['data'],'GET','/v1/models',token=SECRET)[0]==401
                status,listed=call(ports['admin'],'GET','/api/keys');assert status==200
                assert len(listed['keys'])==2 and 'digest' not in json.dumps(listed)
                assert next(k for k in listed['keys'] if k['id']=='import-1')['limits']==dict.fromkeys(LIMITS)
                assert next(k for k in listed['keys'] if k['id']=='import-1')['models'] is None
                assert next(k for k in listed['keys'] if k['id']=='import-1')['imageModels'] is None
                first=next(k for k in listed['keys'] if k['id']=='import-0')
                assert update(ports['admin'],first,enabled=True)[0]==200
                assert call(ports['data'],'GET','/v1/models',token=SECRET)[0]==200
                assert call(ports['data'],'GET','/v1/models',token=OTHER)[0]==401
                request=dict(model='synthetic-text',input='synthetic',stream=False)
                assert call(ports['data'],'POST','/v1/responses',request,token=SECRET)[0]==200
                sock=dial(ports['data'],token=SECRET)
                try:
                    events=turn(sock,dict(type='response.create',model='synthetic-text',input='synthetic'))
                    assert events[-1]['type']=='response.completed'
                finally:sock.close()
                latest(dbpath,'settled');assert provider.calls==2
                assert call(ports['data'],'POST','/v1/responses',request,token=SECRET)[0]!=200
                assert provider.calls==2
            finally:stop(gateway)
            gateway,ports=start(binary,config,target,admin_token_file=admin)
            try:
                assert call(ports['data'],'GET','/v1/models',token=OTHER)[0]==401
                assert call(ports['data'],'POST','/v1/responses',request,token=SECRET)[0]!=200
                assert provider.calls==2
                listed=call(ports['admin'],'GET','/api/keys')[1]
                assert next(k for k in listed['keys'] if k['id']=='import-1')['limits']==dict.fromkeys(LIMITS)
                assert next(k for k in listed['keys'] if k['id']=='import-1')['models'] is None
                assert next(k for k in listed['keys'] if k['id']=='import-1')['imageModels'] is None
                first=next(k for k in listed['keys'] if k['id']=='import-0')
                status,rotated=call(ports['admin'],'POST','/api/keys/import-0/rotate',dict(revision=first['revision']))
                assert status==201
                assert call(ports['data'],'GET','/v1/models',token=SECRET)[0]==401
                assert call(ports['data'],'GET','/v1/models',token=rotated['secret'])[0]==200
                assert call(ports['data'],'POST','/v1/responses',request,token=rotated['secret'])[0]!=200
                assert provider.calls==2,'Rotation reset old usage'
            finally:stop(gateway)
        finally:provider.shutdown();provider.server_close();thread.join(3);assert not thread.is_alive()
        # A real SQLite failure on the second row must roll back both first row and its audit.
        atomic=root/'atomic';atomic.mkdir()
        gateway,_=start(binary,config,atomic,admin_token_file=admin);stop(gateway)
        with sqlite3.connect(atomic/'state/core.sqlite') as db:
            db.execute("CREATE TRIGGER reject_second BEFORE INSERT ON managed_keys WHEN NEW.id='import-1' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        assert invoke(atomic,manifest).returncode!=0
        with sqlite3.connect(atomic/'state/core.sqlite') as db:
            assert db.execute('SELECT COUNT(*) FROM managed_keys').fetchone()[0]==0
            assert db.execute('SELECT COUNT(*) FROM key_events').fetchone()[0]==0
            db.execute('DROP TRIGGER reject_second')
        assert invoke(atomic,manifest).returncode==0
        empty=root/'empty';empty.mkdir();gateway,_=start(binary,config,empty,admin_token_file=admin);stop(gateway)
        backup=root/'empty-backup';restored=root/'restored';restored.mkdir()
        for directory,args in [(empty,['--backup',str(backup)]),(restored,['--restore',str(backup)])]:
            result=subprocess.run([binary,*args],env=dict(PATH=os.defpath,CODEXONE_DATA_DIRECTORY=str(directory/'state')),
                capture_output=True,timeout=15)
            assert result.returncode==0,'Actual empty snapshot restore fixture failed'
        assert invoke(restored,manifest).returncode!=0,'Import bypassed restored maintenance state'
        for file in target.rglob('*'):
            if file.is_file() and file.suffix not in ('.json',):
                assert SECRET.encode() not in file.read_bytes() and OTHER.encode() not in file.read_bytes()
    print('PASS: private atomic offline digest staging, bad-source/permissions/capacity/admin/lock rejection, real HTTP/WS single-Key activation, restart/rotation limits and no raw secrets')


if __name__=='__main__':main()
