#!/usr/bin/env python3
"""Provider WS error events reach JSON/SSE/native clients sanitized; foreign responses stay rejected."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import time
from verify_protocol import TOKEN, start, stop
from verify_text_contract import Provider as WireProvider, call, rows

PRIVATE='synthetic-private-provider-error-never-log'
ORG='org-SyntheticPrivateOrg42'
# Provider error events reach the client with their actionable code; account identifiers do not.
CASES={
    'stream': ('upstream_rejected', 502, {'param':'stream','code':'invalid_request'}),
    'reasoning': ('upstream_rejected', 400, {'param':'reasoning.summary','code':'unsupported_value'}),
    'authentication': ('upstream_authentication_rejected', 502, {'code':'invalid_api_key'}),
    'rate': ('upstream_rate_limited', 429, {'code':'rate_limit_exceeded'}),
    'usage': ('upstream_rate_limited', 429, {'type':'usage_limit_reached','resets_in_seconds':30}),
    'response': ('invalid_upstream_turn', 502, None),
}

class Provider(WireProvider):
    def sequence(self, request):
        with self.server.guard:
            self.server.calls+=1
            index=self.server.calls
        mode=self.server.mode;error=CASES[mode][2]
        if error is not None:
            fields={**error,'message':f'{PRIVATE} for {ORG}'}
            event=dict(type='error',error=fields) if self.server.nested else dict(type='error',**fields)
            if mode=='reasoning':event['status']=400
            return [event]
        created=dict(type='response.created',response=dict(id=f'synthetic-response-{index}',status='in_progress',output=[]))
        return [created,dict(type='response.completed',response=dict(id=f'synthetic-foreign-{index}',status='completed',output=[]))]

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
                            _,events=call(ports['data'],route,dict(model='synthetic-contract',input='synthetic error probe'))
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
                    finally:stop(process)
        print(f'PASS: {server.calls} provider error/foreign-response turns; actionable sanitized errors across JSON/SSE/native, no provider payload logs, zero-cost explicit refusals, foreign-response unknown ledger and no replay',flush=True)
    finally:server.shutdown();server.server_close();worker.join(10)

if __name__=='__main__':main()
