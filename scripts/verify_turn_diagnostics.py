#!/usr/bin/env python3
"""Provider WS error events reach JSON/SSE/native clients sanitized; foreign responses stay rejected."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from verify_protocol import TOKEN, dump_gateway_failure, start, stop
from verify_text_contract import Provider as WireProvider, call, rows
from verify_admin import ADMIN, document, request
from verify_keys import call as key_api

PRIVATE='synthetic-private-provider-error-never-log'
ORG='org-SyntheticPrivateOrg42'
# Provider error events reach the client with their actionable code; account identifiers do not.
CASES={
    'stream': ('upstream_rejected', 400, {'param':'stream','code':'invalid_request'}),
    'reasoning': ('upstream_rejected', 400, {'param':'reasoning.summary','code':'unsupported_value'}),
    'authentication': ('upstream_authentication_rejected', 502, {'code':'invalid_api_key'}),
    'rate': ('upstream_rate_limited', 429, {'code':'rate_limit_exceeded'}),
    'usage': ('upstream_rate_limited', 429, {'type':'usage_limit_reached','resets_in_seconds':30}),
    'budget': ('upstream_rejected', 400, {'code':'budget_reached'}),
    'response': ('invalid_upstream_turn', 502, None),
}

class Provider(WireProvider):
    def sequence(self, request):
        with self.server.guard:
            self.server.calls+=1
            index=self.server.calls
        if request.get('input') == 'synthetic held turn':
            self.server.held.set()
            assert self.server.release.wait(5)
            return [dict(type='response.completed', response=dict(id='synthetic-held',
                status='completed', output=[], usage=dict(input_tokens=2, output_tokens=1)))]
        mode=self.server.mode;error=CASES[mode][2]
        if error is not None:
            fields={**error,'message':f'{PRIVATE} for {ORG}'}
            event=dict(type='error',error=fields) if self.server.nested else dict(type='error',**fields)
            if mode=='reasoning':event['status']=400
            return [event]
        created=dict(type='response.created',response=dict(id=f'synthetic-response-{index}',status='in_progress',output=[]))
        return [created,dict(type='response.completed',response=dict(id=f'synthetic-foreign-{index}',status='completed',output=[]))]

def verify_selection_diagnostics(root, binary, server):
    root.mkdir(mode=0o700)
    config = root / 'identity.json'
    model = dict(id='synthetic-contract', inputMicrosPerMillion=0, outputMicrosPerMillion=0,
        catalog={'reasoningEfforts': ['high'], 'baseInstructions': 'Synthetic diagnostic fixture'})
    config.write_text(json.dumps(dict(
        managedKeys=True, namespace='synthetic', identity='synthetic', models=[model], reservedMicros=1,
        upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1', upstreamTransport='websocket')))
    config.chmod(0o600)
    admin = root / 'admin'
    admin.write_text(ADMIN)
    admin.chmod(0o600)
    process, ports = start(str(binary.resolve()), config, root, admin_token_file=admin,
                           business_day_offset='+08:00')
    before = server.calls
    cases = [
        ('gpt-6-synthetic', dict(reasoning={'effort': 'xhigh'}), 'gpt-6-synthetic', 'xhigh', None, 'model_not_allowed'),
        ('gpt-6-synthetic', dict(reasoning={'effort': 'high'}, reasoning_effort='low'),
         'gpt-6-synthetic', 'high', 'low', 'model_not_allowed'),
        (TOKEN, dict(reasoning={'effort': TOKEN}), 'unrecognized', 'invalid', None, 'model_not_allowed'),
        ('synthetic-contract', {}, 'synthetic-contract', 'missing', None, 'reasoning_effort_missing'),
        ('synthetic-contract', dict(reasoning={'effort': 'low'}), 'synthetic-contract',
         'low', None, 'reasoning_effort_not_allowed'),
        ('synthetic-contract', dict(reasoning={'effort': 'high'}, reasoning_effort='low'),
         'synthetic-contract', 'high', 'low', 'reasoning_effort_legacy_field'),
    ]
    try:
        status, created = key_api(ports['admin'], 'POST', '/api/keys', dict(
            principal='synthetic', models=['synthetic-contract'], limits={'tokens': 1000, 'active': 1},
            reasoningEfforts={'synthetic-contract': ['high']}, catalogRevision=0))
        assert status == 201
        token = created['secret']
        expected = []
        for route in ('json', 'sse', 'native'):
            for raw_model, fields, model, effort, legacy, reason in cases:
                status, events = call(ports['data'], route, {
                    'model': raw_model, 'input': PRIVATE, **fields,
                }, token=token)
                assert (events[-1]['status'] if route == 'native' else status) == 403
                error = events[-1]['error']
                code = 'model_not_allowed' if reason == 'model_not_allowed' else 'reasoning_effort_not_allowed'
                assert error['code'] == code and 'requested_model' not in error
                assert 'requested_reasoning_effort' not in error and 'legacy_reasoning_effort' not in error
                expected.append((error['request_id'], model, effort, legacy, reason))
        assert server.calls == before and rows(root) == []
        hour = int(time.time()) // 3600 * 3600
        window = f'start={hour - 3600}&end={hour + 7200}&rejectedOnly=true'
        headers = {'Authorization': 'Bearer ' + ADMIN}
        usage = document(request(ports['admin'], 'GET', f'/api/usage?{window}', headers=headers))
        recorded = {row['requestID']: row for row in usage['rows']}
        assert usage['totals']['admitted'] == 0 and usage['totals']['recordedRejections'] == len(expected)
        assert usage['businessDay'] == {'offsetMinutes': 480}
        for request_id, model, effort, legacy, reason in expected:
            row = recorded[request_id]
            assert row['model'] == ('synthetic-contract' if model == 'synthetic-contract' else None), row
            assert row['reasoningEffort'] == (legacy if reason == 'reasoning_effort_legacy_field' else effort), row
            assert row['rejectionReason'] == reason, row
        filtered = document(request(ports['admin'], 'GET',
            f'/api/usage?{window}&model=synthetic-contract&reasoningEffort=low'
            '&rejectionGroup=invalid_request:reasoning_effort_legacy_field&limit=1', headers=headers))
        assert filtered['totals']['recordedRejections'] == 3 and len(filtered['rows']) == 1
        assert filtered['rows'][0]['rejectionReason'] == 'reasoning_effort_legacy_field'
        server.held, server.release = threading.Event(), threading.Event()
        valid = dict(model='synthetic-contract', input='synthetic held turn', reasoning={'effort': 'high'})
        with ThreadPoolExecutor(max_workers=1) as worker:
            held = worker.submit(call, ports['data'], 'json', valid, token)
            try:
                assert server.held.wait(3)
                for route in ('json', 'sse', 'native'):
                    status, events = call(ports['data'], route, {**valid, 'input': PRIVATE}, token=token)
                    error = events[-1]['error']
                    assert (events[-1]['status'] if route == 'native' else status) == 429
                    assert error['code'] == 'quota_or_policy_denied'
                    with sqlite3.connect(root / 'state/core.sqlite') as db:
                        assert db.execute('SELECT COUNT(*) FROM attempts').fetchone() == (1,)
                        assert db.execute(
                            'SELECT failure,model FROM request_diagnostics WHERE request_id=?',
                            (error['request_id'],)).fetchone() == ('local_capacity', 'synthetic-contract')
                assert server.calls == before + 1
            finally:
                server.release.set()
            assert held.result()[0] == 200
        process.terminate()
        process.wait(10)
        logs = process.stdout.read()
        for request_id, model, effort, legacy, _ in expected[:16]:
            line = next((line for line in logs.splitlines() if request_id.encode() in line
                         and b'Protocol request rejected' in line), b'')
            assert f'requested_model={model} '.encode() in line, line
            assert f'requested_reasoning_effort={effort} '.encode() in line, line
            if legacy:
                assert f'legacy_reasoning_effort={legacy} '.encode() in line, line
            else:
                assert b'legacy_reasoning_effort=' not in line, line
        assert all(value.encode() not in logs for value in (TOKEN, token, PRIVATE))
        assert logs.count(b'Protocol request rejected') == 16
        print('PASS: HTTP JSON/SSE and native WS selection/capacity diagnostics, filters, business day and log bounds', flush=True)
    finally:
        stop(process)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',0),Provider);server.guard=threading.Lock();server.calls=0
    worker=threading.Thread(target=server.serve_forever);worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-turn-diagnostics-') as temporary:
            for case,(code,status,fields) in CASES.items():
                for nested in ((True,False) if fields is not None and 'type' not in fields else (True,)):
                    server.mode=case;server.nested=nested;root=Path(temporary)/(case+str(nested));root.mkdir(mode=0o700)
                    config=root/'identity.json';config.write_text(json.dumps(dict(principal='synthetic',keyID='synthetic',namespace='synthetic',identity='synthetic',
                        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),models=[dict(id='synthetic-contract',inputMicrosPerMillion=0,outputMicrosPerMillion=0)],reservedMicros=1,
                        upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1',upstreamTransport='websocket')));config.chmod(0o600)
                    process,ports=start(str(args.binary.resolve()),config,root);before=server.calls;request_ids=[]
                    try:
                        for route in ('json','sse','native'):
                            try:
                                _,events=call(ports['data'],route,dict(model='synthetic-contract',input='synthetic error probe'))
                            except EOFError as error:
                                raise AssertionError(('socket closed before the error frame', case, nested, route)) from error
                            error=events[-1]['error'];provider=fields is not None and code!='upstream_authentication_rejected'
                            assert ORG not in json.dumps(events) and 'reason' not in error,(case,events)
                            if provider:
                                assert all(error[k]==v for k,v in fields.items()) and '[redacted]' in error['message'],(case,route,events)
                            else:
                                assert error['code']==code and error['request_id'] in error['message'],(case,nested,route,events)
                            if route=='native':assert events[-1].get('status')==status,(case,events)
                            request_ids.append(error['request_id'])
                        deadline=time.monotonic()+4
                        while len(rows(root))!=3 or any(s=='intent' for s,_,_ in rows(root)):
                            assert time.monotonic()<deadline;time.sleep(.02)
                        if case == 'response':
                            assert all(s=='unknown' and u is None for s,_,u in rows(root)),rows(root)
                        else:
                            assert all(s=='settled' and u['completeness']=='complete' and u['estimatedMicros']==0
                                       and u['providerRejectedBeforeOutput'] for s,_,u in rows(root)),rows(root)
                        process.terminate();process.wait(10);logs=process.stdout.read()
                        for request_id in request_ids:
                            assert any(request_id.encode() in line and ('code='+code).encode() in line for line in logs.splitlines()),(case,request_id,logs)
                        if case=='response':assert b'reason=upstream_turn_response_id' in logs
                        assert PRIVATE.encode() not in logs and ORG.encode() not in logs and TOKEN.encode() not in logs
                        assert server.calls==before+3,'Unexpected replay'
                    except Exception:
                        dump_gateway_failure(process)
                        raise
                    finally:stop(process)
            verify_selection_diagnostics(Path(temporary)/'selection',args.binary,server)
        print(f'PASS: {server.calls} provider error/foreign-response turns; actionable sanitized errors across JSON/SSE/native, no provider payload logs, zero-cost explicit refusals, foreign-response unknown ledger and no replay',flush=True)
    finally:server.shutdown();server.server_close();worker.join(10)

if __name__=='__main__':main()
