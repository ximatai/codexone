#!/usr/bin/env python3
"""Synthetic mixed ingress/output acceptance; native Linux CI is required for capacity claims.

Consumes an existing candidate image; never builds, pulls, or contacts a provider.
The stimulus and gateway have separate 512/768 MiB cgroups and share loopback only.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import secrets
import statistics
import tempfile
import threading
import time
import traceback
import sys
import uuid

import verify_capacity as capacity

MIB = capacity.MIB
MODEL = capacity.MODEL


def exact_body(size, nonce):
    document = {'model': MODEL, 'input': nonce, 'instructions': '', 'stream': False}
    initial = json.dumps(document, separators=(',', ':')).encode()
    document['instructions'] = 'x' * (size - len(initial))
    result = json.dumps(document, separators=(',', ':')).encode()
    assert len(result) == size
    return result


def image_body():
    # Eight independently bounded opaque output containers; no input codec claim.
    encoded = base64.b64encode(b'synthetic-output-' + b'x' * (int(5.75*MIB)*3//4-17)).decode()
    document = {'created': 1, 'data': [{'b64_json': encoded} for _ in range(8)],
                'usage': {'input_tokens': 2, 'output_tokens': 3,
                          'input_tokens_details': {'text_tokens': 1, 'image_tokens': 1}}}
    result = json.dumps(document, separators=(',', ':')).encode()
    assert 45*MIB < len(result) < 47*MIB
    assert len(encoded) < 8*MIB
    return result


def worker(root, ports, idle_seconds):
    admin = (root/'admin').read_text()
    expected_image_digest = hashlib.sha256(image_body()).digest()
    expected_image_bytes = len(image_body())
    release = threading.Event()
    guard = threading.Condition()
    calls = []
    seen = set()
    progress = {'phase': 'starting'}
    def phase(name):
        progress['phase'] = name
        capacity.private_json(root/'progress.json', progress)
    def until(predicate, timeout=15):
        end = time.monotonic()+timeout
        with guard:
            while not predicate():
                remaining = end-time.monotonic()
                assert remaining > 0, 'Provider barrier timeout'
                guard.wait(min(.1, remaining))
    class Provider(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_): pass
        def handle(self):
            try: super().handle()
            except (BrokenPipeError, ConnectionResetError, TimeoutError): pass
        def do_POST(self):
            assert self.headers.get('Content-Encoding') is None
            length = int(self.headers['Content-Length'])
            assert 0 < length <= 33*MIB
            document = json.loads(self.rfile.read(length))
            nonce = document.get('input', document.get('prompt'))
            assert isinstance(nonce, str) and nonce.startswith('mixed-')
            digest = hashlib.sha256(nonce.encode()).digest()
            with guard:
                assert digest not in seen, 'Provider replay'
                seen.add(digest)
                calls.append((nonce, self.path))
                index = len(calls)
                guard.notify_all()
            if 'hold' in nonce:
                assert release.wait(40), 'Held provider was not released'
            if '/images/' in self.path:
                assert document.get('n') == 8, 'Provider did not receive requested image count'
                body = image_body()
            else:
                body = json.dumps({'id': f'resp_{index}', 'status': 'completed', 'output': [],
                    'usage': {'input_tokens': 2, 'output_tokens': 3,
                              'input_tokens_details': {'cached_tokens': 0}}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            for offset in range(0, len(body), 65536):
                self.wfile.write(body[offset:offset+65536])
            self.wfile.flush()
    provider = ThreadingHTTPServer(('127.0.0.1', ports['provider']), Provider)
    provider.daemon_threads = True
    owner = threading.Thread(target=provider.serve_forever)
    owner.start()
    stop = threading.Event()
    management = []
    failures = []
    monitor_thread = None
    results = []
    keys = []
    def management_call(path):
        began = time.monotonic()
        connection = http.client.HTTPConnection('127.0.0.1', ports['admin'], timeout=2)
        try:
            connection.request('GET', path, headers={'Authorization': 'Bearer '+admin})
            reply = connection.getresponse()
            reply.read(2*MIB)
            assert reply.status == 200
            return time.monotonic()-began
        finally: connection.close()
    def monitor():
        while not stop.is_set():
            for path in ('/health/live', '/api/keys', '/api/runtime/storage'):
                try:
                    management.append({'phase': progress['phase'], 'endpoint': path,
                                       'seconds': management_call(path)})
                except Exception as error:
                    failures.append(type(error).__name__)
            stop.wait(1)
    def request(body, token, path='/v1/responses', slow=False, cancel=False):
        conn = http.client.HTTPConnection('127.0.0.1', ports['data'], timeout=45)
        started = time.monotonic()
        try:
            conn.request('POST', path, body, {'Authorization':'Bearer '+token,
                         'Content-Type':'application/json'})
            reply = conn.getresponse()
            if cancel:
                received = len(reply.read(65536))
                assert received > 0 and reply.status == 200
                return {'status': reply.status, 'cancelled': True, 'bytes': received}
            chunks = []
            image_output = '/images/' in path and reply.status == 200
            digest = hashlib.sha256()
            byte_count = 0
            while True:
                part = reply.read(65536)
                if not part: break
                byte_count += len(part)
                if image_output: digest.update(part)
                else: chunks.append(part)
                if slow: time.sleep(.004)
            payload = b''.join(chunks)
            if image_output:
                assert byte_count == expected_image_bytes and digest.digest() == expected_image_digest
            elif reply.status == 200:
                document = json.loads(payload)
                assert document['status'] == 'completed'
            return {'status': reply.status, 'cancelled': False, 'bytes': byte_count,
                    'seconds': time.monotonic()-started}
        finally: conn.close()
    try:
        end = time.monotonic()+40
        while True:
            try:
                management_call('/health/live')
                break
            except (OSError, http.client.HTTPException):
                assert time.monotonic() < end
                time.sleep(.2)
        for index in range(4):
            status, body = capacity.response(ports['admin'], '/api/keys', admin,
                {'principal': f'synthetic-mixed-{index}', 'models':[MODEL], 'visionInput':True,
                 'imageGeneration':True, 'imageModels':['synthetic-image'],
                 'limits':{'tokens':1000000, 'active':8}})
            assert status == 201
            keys.append(json.loads(body)['secret'])
        phase('baseline')
        monitor_thread = threading.Thread(target=monitor)
        monitor_thread.start()
        time.sleep(4)
        with ThreadPoolExecutor(max_workers=6) as pool:
            for turn in range(3):
                phase(f'round-{turn+1}-budget')
                release.clear()
                names = [f'mixed-{turn}-hold-{i}' for i in range(2)]
                pending = [pool.submit(request, exact_body(32*MIB, name), keys[i]) for i, name in enumerate(names)]
                until(lambda: all(any(row[0] == name for row in calls) for name in names))
                # Empty lease must wait while both 32 MiB owners are held.
                waiting_name = f'mixed-{turn}-wait'
                waiter = pool.submit(request, exact_body(9*MIB, waiting_name), keys[2])
                small = request(exact_body(8*MIB-1024, f'mixed-{turn}-small'), keys[2])
                assert small['status'] == 200
                time.sleep(.3)
                assert not waiter.done()
                assert not any(row[0] == waiting_name for row in calls)
                release.set()
                batch = [future.result(timeout=40) for future in pending+[waiter]]
                assert all(row['status'] == 200 for row in batch)
                results.extend(batch+[small])
                phase(f'round-{turn+1}-outputs')
                release.clear()
                held_name = f'mixed-{turn}-output-hold'
                held = pool.submit(request, exact_body(32*MIB, held_name), keys[0])
                until(lambda: any(row[0] == held_name for row in calls))
                generation = pool.submit(request, json.dumps({'model':'synthetic-image',
                    'prompt':f'mixed-{turn}-generation', 'output_format':'gif', 'n':8}).encode(), keys[1],
                    '/v1/images/generations', True)
                generated = generation.result(timeout=40)
                assert generated['status'] == 200
                results.append(generated)
                edit = request(json.dumps({'model':'synthetic-image','prompt':f'mixed-{turn}-edit','n':8,
                    'images':[{'image_url':'data:image/png;base64,'+base64.b64encode(capacity.png_payload()).decode()}]}).encode(),
                    keys[3], '/v1/images/edits', cancel=True)
                results.append(edit)
                assert request(exact_body(1024, f'mixed-{turn}-alive'), keys[2])['status'] == 200
                # Disconnect after confirmed dispatch, before provider result. Its unknown
                # responsibility must survive local memory/socket reclamation.
                cancelled_name = f'mixed-{turn}-cancel-hold'
                cancelled = http.client.HTTPConnection('127.0.0.1', ports['data'], timeout=20)
                try:
                    cancelled.request('POST', '/v1/responses', exact_body(32*MIB, cancelled_name),
                        {'Authorization':'Bearer '+keys[2], 'Content-Type':'application/json'})
                    until(lambda: any(row[0] == cancelled_name for row in calls))
                finally: cancelled.close()
                time.sleep(.3)
                release.set()
                assert held.result(timeout=40)['status'] == 200
                assert request(exact_body(32*MIB, f'mixed-{turn}-recovered'), keys[0])['status'] == 200
                phase(f'round-{turn+1}-recovery')
                time.sleep(idle_seconds)
        assert not failures, 'Management API failed during mixed load'
        with guard:
            assert len(calls) == len(seen) == 30, 'Unexpected dispatch count'
        report = {'rounds':3, 'providerCalls':len(calls), 'expectedCalls':30,
                  'management':management, 'managementFailures':failures, 'operations':results,
                  'nativeImageBytes':len(image_body()), 'idleSecondsPerRound':idle_seconds,
                  'limitations':['HTTP upstream only; multiplexed lanes are separate verify_websocket.py evidence',
                    'compression off; zstd has separate acceptance',
                    'threads are OS threads, not Swift tasks',
                    'queue/lease recovery is behavioral, no direct runtime snapshot',
                    'cancellation after buffered native output may already be settled; never assumes zero charge']}
        capacity.private_json(root/'worker-result.json', report)
        phase('complete')
    finally:
        release.set()
        stop.set()
        if monitor_thread: monitor_thread.join(8)
        provider.shutdown(); provider.server_close(); owner.join(5)
        assert not owner.is_alive()


def configuration():
    value = capacity.config_document('http')
    value.update(executionTimeoutSeconds=60, firstResponseTimeoutSeconds=60,
                 upstreamRequestCompression='off', imageConcurrency=1)
    return value


def assert_ledger(rows):
    expected = {'synthetic-mixed-0':9, 'synthetic-mixed-1':6,
                'synthetic-mixed-2':12, 'synthetic-mixed-3':3}
    assert sum(row['count'] for row in rows) == 30, 'Ledger/provider count mismatch'
    assert all(row['state'] in ('settled', 'unknown') for row in rows), 'Unfinished attempt'
    assert {row['principal'] for row in rows} == set(expected), 'Unexpected principal'
    for principal, count in expected.items():
        owned = [row for row in rows if row['principal'] == principal]
        assert sum(row['count'] for row in owned) == count, 'Wrong owner count'
        unknown = sum(row['count'] for row in owned if row['state'] == 'unknown')
        if principal in ('synthetic-mixed-0', 'synthetic-mixed-1'):
            assert unknown == 0, 'Successful request lost settlement'
        elif principal == 'synthetic-mixed-2':
            assert unknown == 3, 'Confirmed dispatch cancellation lost responsibility'
            assert sum(row['reserved'] for row in owned if row['state'] == 'unknown') == 3
        for row in owned:
            if row['state'] == 'settled':
                assert row['complete'] == row['count'], 'Successful request lacks complete usage'
            else:
                assert row['reserved'] == row['count'], 'Unknown reservation changed'


LEDGER_SQL = ("SELECT principal,state,COUNT(*) AS count,SUM(reserved) AS reserved, "
              "SUM(CASE WHEN json_extract(usage_json,'$.completeness')='complete' THEN 1 ELSE 0 END) AS complete "
              "FROM attempts GROUP BY principal,state;")


def recovery_medians(series):
    medians = []
    for turn in range(3):
        rows = [row for row in series if row['phase'] == f'round-{turn+1}-recovery']
        assert len(rows) >= 25, 'Missing continuous 60-second recovery samples'
        # Last ten samples are about twenty seconds; first round is the warmed baseline.
        medians.append(statistics.median(row['rssBytes'] for row in rows[-10:]))
    assert all(value <= medians[0]+32*MIB for value in medians[1:]), 'Recovery RSS platform grew beyond 32 MiB'
    return medians


def container_evidence(identifier):
    if not identifier:
        return {'available':False}
    try:
        result = capacity.run(['docker','inspect',identifier],ok=False)
        if result.returncode:
            return {'available':False}
        state = json.loads(result.stdout)[0]['State']
        evidence = {'available':True, 'state':{key:state.get(key) for key in
                    ('Running','ExitCode','OOMKilled','Dead','Restarting','Paused')}}
        try:
            evidence['resources'] = capacity.resources(identifier)
        except Exception:
            evidence['resourcesAvailable'] = False
        return evidence
    except Exception:
        return {'available':False}


def orchestrate(args):
    assert platform.system() == 'Linux' and platform.machine() in ('x86_64','amd64'), 'Native Linux amd64 required'
    run = capacity.run
    output = args.output.resolve()
    assert not output.exists(), 'Refuse overwriting evidence'
    runtime = json.loads(run(['docker','image','inspect',args.image]).stdout)[0]
    harness = json.loads(run(['docker','image','inspect',args.harness_image]).stdout)[0]
    info = json.loads(run(['docker','info','--format','{{json .}}']).stdout)
    assert runtime['Architecture'] == harness['Architecture'] == 'amd64'
    assert runtime['Os'] == harness['Os'] == 'linux'
    assert info['Architecture'] in ('x86_64','amd64')
    identifier = uuid.uuid4().hex
    volume = 'codexone-capacity-'+identifier
    worker_id = gateway_id = None
    uid = os.getuid() or 10001
    gid = os.getgid() if os.getuid() else 10001
    previous = os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-mixed-') as temporary:
            root = Path(temporary)
            (root/'admin').write_text(secrets.token_urlsafe(48))
            (root/'admin').chmod(0o600)
            capacity.private_json(root/'identity.json', configuration())
            if os.getuid() == 0:
                for item in root.iterdir(): os.chown(item, uid, gid)
                os.chown(root,uid,gid)
            try:
                run(['docker','volume','create','--label','codexone.capacity='+identifier,volume])
                run(['docker','run','--rm','--network','none','--read-only','--user','0:0',
                     '--label','codexone.capacity='+identifier,'--memory','64m','--memory-swap','64m',
                     '--pids-limit','16','--cap-drop','ALL','--cap-add','CHOWN','--cap-add','FOWNER',
                     '--cap-add','DAC_OVERRIDE','--security-opt','no-new-privileges:true',
                     '--mount',f'type=volume,src={volume},dst=/var/lib/codexone,volume-nocopy',
                     '--entrypoint','sh',runtime['Id'],'-ec',
                     f'test -z "$(find /var/lib/codexone -mindepth 1 -maxdepth 1 -print -quit)"; chown {uid}:{gid} /var/lib/codexone; chmod 700 /var/lib/codexone'])
                common = ['--read-only','--user',f'{uid}:{gid}','--cap-drop','ALL',
                          '--security-opt','no-new-privileges:true','--cpus','1','--pids-limit','128',
                          '--label','codexone.capacity='+identifier]
                worker_id = run(['docker','run','-d','--network','none',*common,
                    '--memory','512m','--memory-swap','512m','--tmpfs','/tmp:rw,nosuid,size=64m,mode=1777',
                    '--env','PYTHONDONTWRITEBYTECODE=1','--mount',f'type=bind,src={root},dst=/run/capacity',
                    '--mount',f'type=bind,src={Path(__file__).resolve().parent},dst=/test/scripts,readonly',
                    '--entrypoint','python3',harness['Id'],'/test/scripts/verify_mixed_capacity.py',
                    '--worker','--root','/run/capacity']).stdout.decode().strip()
                gateway_id = run(['docker','run','-d','--network','container:'+worker_id,*common,
                    '--memory','768m','--memory-swap','768m','--tmpfs','/tmp:rw,noexec,nosuid,size=16m,mode=1777',
                    '--mount',f'type=bind,src={root},dst=/run/capacity,readonly',
                    '--mount',f'type=volume,src={volume},dst=/var/lib/codexone,volume-nocopy',
                    '--env','CODEXONE_IDENTITY_CONFIG=/run/capacity/identity.json',
                    '--env','CODEXONE_ADMIN_TOKEN_FILE=/run/capacity/admin',runtime['Id']]).stdout.decode().strip()
                series = []
                began = time.monotonic()
                while True:
                    state = json.loads(run(['docker','inspect',worker_id]).stdout)[0]['State']
                    if not state['Running']:
                        assert state['ExitCode'] == 0 and not state['OOMKilled'], 'Mixed stimulus failed; private diagnostics withheld'
                        break
                    assert time.monotonic()-began < 600, 'Mixed worker exceeded deadline'
                    name = json.loads((root/'progress.json').read_text())['phase'] if (root/'progress.json').exists() else 'starting'
                    series.append({'elapsedSeconds':round(time.monotonic()-began,2),
                                   'phase':name, **capacity.resources(gateway_id)})
                    if len(series)%15 == 0: print('PROGRESS: mixed '+name, flush=True)
                    time.sleep(2)
                report = json.loads((root/'worker-result.json').read_text())
                rows = json.loads(run(['docker','exec',gateway_id,'sqlite3','-readonly','-json',
                                       '/var/lib/codexone/core.sqlite',LEDGER_SQL]).stdout)
                assert_ledger(rows)
                baseline = [row for row in series if row['phase'] == 'baseline']
                assert baseline
                for turn in range(3):
                    recovery = [row for row in series if row['phase'] == f'round-{turn+1}-recovery']
                    assert len(recovery) >= 25, 'Missing continuous 60-second recovery samples'
                    assert recovery[-1]['fds'] <= max(row['fds'] for row in baseline)+8
                    assert recovery[-1]['rssBytes'] < 768*MIB*.7, 'Recovery RSS exceeds existing capacity envelope'
                warmed_medians = recovery_medians(series)
                assert all(row['memoryEvents'].get('oom_kill',0) == 0 and row['swapMaximumBytes'] == 0 for row in series)
                run(['docker','stop','--time','30',gateway_id],timeout=40)
                state = json.loads(run(['docker','inspect',gateway_id]).stdout)[0]['State']
                assert state['ExitCode'] == 0 and not state['OOMKilled']
                report.update(success=True, recoveryTailMedianRSSBytes=warmed_medians,
                    containerEvidence={'worker':container_evidence(worker_id),'gateway':container_evidence(gateway_id)}, resources=series, ledger=rows, platform='native-linux-amd64',
                    runtimeImageID=runtime['Id'], sourceRevision=runtime['Config']['Labels']['org.opencontainers.image.revision'],
                    harnessImageID=harness['Id'], harnessSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    gatewayMemoryBytes=768*MIB, stimulusMemoryBytes=512*MIB,
                    engineCPUs=info['NCPU'], engineMemoryBytes=info['MemTotal'])
                serialized = json.dumps(report, indent=2)
                assert (root/'admin').read_text() not in serialized and 'co1_' not in serialized
                output.mkdir(parents=True,mode=0o700)
                (output/'report.json').write_text(serialized+'\n')
                print('PASS: native Linux mixed capacity; direct task/queue/lease snapshots remain unavailable',flush=True)
            except Exception:
                failed_containers = {'worker':container_evidence(worker_id),
                                     'gateway':container_evidence(gateway_id)}
                if not output.exists():
                    output.mkdir(parents=True,mode=0o700)
                    capacity.private_json(output/'report.json', {
                        'success':False, 'platform':'native-linux-amd64',
                        'containerEvidence':failed_containers,
                        'resources':locals().get('series', []),
                        'limitations':['Failure evidence only; no capacity acceptance claimed']})
                if worker_id:
                    captured = run(['docker','logs',worker_id],ok=False)
                    for line in (captured.stdout+captured.stderr).decode(errors='replace').splitlines():
                        # Only our static class/file/line diagnostic; never emit payloads.
                        if line.startswith('FAIL: mixed ') and len(line) < 512:
                            import re
                            if re.fullmatch(r'FAIL: mixed [A-Za-z]+ at [A-Za-z0-9_.,:]+', line):
                                print(line, flush=True)
                raise
            finally:
                capacity.cleanup_owned(identifier,volume,(gateway_id,worker_id))
    finally: os.umask(previous)


def smoke(args):
    from verify_protocol import start, stop
    import sqlite3
    assert platform.system() == 'Darwin', '--binary is macOS functional smoke only'
    with tempfile.TemporaryDirectory(prefix='codexone-mixed-smoke-') as temporary:
        root = Path(temporary)
        admin = root/'admin'
        admin.write_text('synthetic-mixed-admin-token-for-smoke')
        admin.chmod(0o600)
        config = root/'identity.json'
        capacity.private_json(config, configuration())
        process, ports = start(str(args.binary.resolve()),config,root,admin_token_file=admin)
        try:
            worker(root,{**ports,'provider':19090},1)
            with sqlite3.connect(root/'state/core.sqlite') as db:
                db.row_factory=sqlite3.Row
                rows=[dict(row) for row in db.execute(LEDGER_SQL)]
            assert_ledger(rows)
            print('PASS: macOS mixed functional smoke; no Linux memory/cgroup or 60-second recovery claim')
        finally: stop(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker',action='store_true')
    parser.add_argument('--root',type=Path)
    parser.add_argument('--image')
    parser.add_argument('--harness-image',default='codexone:v8-verification')
    parser.add_argument('--output',type=Path)
    parser.add_argument('--binary',type=Path,help='macOS functional smoke only, one-second idle')
    args = parser.parse_args()
    if args.worker:
        assert args.root
        worker(args.root,{'admin':18081,'data':18080,'provider':19090},60)
    elif args.binary: smoke(args)
    else:
        assert args.image and args.output
        orchestrate(args)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        frames = traceback.extract_tb(error.__traceback__)
        print('FAIL: mixed '+type(error).__name__+' at '+','.join(Path(frame.filename).name+':'+str(frame.lineno) for frame in frames[-4:]),file=sys.stderr)
        sys.exit(1)
