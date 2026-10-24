#!/usr/bin/env python3
"""Fixed sole-reader reasons over credential-free, independent WS error envelopes."""
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
CASES={
    'stream': ('upstream_turn_provider_stream', {'param':'stream'}),
    'reasoning': ('upstream_turn_provider_reasoning_summary', {'param':'reasoning.summary'}),
    'authentication': ('upstream_turn_provider_authentication', {'code':'invalid_api_key'}),
    'rate': ('upstream_turn_provider_rate_limit', {'code':'rate_limit_exceeded'}),
    'other': ('upstream_turn_provider_error', {'code':PRIVATE,'param':PRIVATE}),
    'created': ('upstream_turn_created', None),
    'response': ('upstream_turn_response_id', None),
    'item': ('upstream_turn_item_id', None),
    'missing-item': ('upstream_turn_missing_item_id', None),
    'unknown-item': ('upstream_turn_unknown_item_id', None),
}

class Provider(WireProvider):
    def sequence(self, request):
        with self.server.guard:
            self.server.calls+=1
            index=self.server.calls
        mode=self.server.mode;error=CASES[mode][1]
        if error is not None:
            fields={**error,'message':PRIVATE}
            return [dict(type='error',error=fields)] if self.server.nested else [dict(type='error',**fields)]
        if mode=='created':return [dict(type='response.completed',response=dict(id=f'synthetic-response-{index}',status='completed',output=[]))]
        created=dict(type='response.created',response=dict(id=f'synthetic-response-{index}',status='in_progress',output=[]))
        if mode=='response':return [created,dict(type='response.completed',response=dict(id=f'synthetic-foreign-{index}',status='completed',output=[]))]
        if mode=='item':return [created,dict(type='response.output_item.added',item=dict(id=False))]
        delta=dict(type='response.output_text.delta',delta=PRIVATE)
        if mode=='unknown-item':delta['item_id']=f'synthetic-foreign-{index}'
        return [created,delta]

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',0),Provider);server.guard=threading.Lock();server.calls=0
    worker=threading.Thread(target=server.serve_forever);worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-turn-diagnostics-') as temporary:
            for case,(reason,fields) in CASES.items():
                for nested in ((True,False) if fields is not None else (True,)):
                    server.mode=case;server.nested=nested;root=Path(temporary)/(case+str(nested));root.mkdir(mode=0o700)
                    config=root/'identity.json';config.write_text(json.dumps(dict(principal='synthetic',keyID='synthetic',namespace='synthetic',identity='synthetic',
                        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),models=[dict(id='synthetic-contract',inputMicrosPerMillion=0,outputMicrosPerMillion=0)],reservedMicros=1,
                        upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1',upstreamTransport='websocket')));config.chmod(0o600)
                    process,ports=start(str(args.binary.resolve()),config,root);before=server.calls
                    try:
                        for route in ('json','sse','native'):
                            _,events=call(ports['data'],route,dict(model='synthetic-contract',input='synthetic error probe'))
                            error=events[-1]['error'];assert error['code']=='invalid_upstream_turn' and error['request_id'] in error['message'],(case,nested,route,events)
                            assert 'reason' not in error
                        deadline=time.monotonic()+4
                        while len(rows(root))!=3 or any(s=='intent' for s,_,_ in rows(root)):
                            assert time.monotonic()<deadline;time.sleep(.02)
                        assert all(s=='unknown' and u is None for s,_,u in rows(root)),rows(root)
                        process.terminate();process.wait(10);logs=process.stdout.read()
                        assert ('reason='+reason).encode() in logs,(case,logs)
                        assert PRIVATE.encode() not in logs and TOKEN.encode() not in logs
                        assert server.calls==before+3,'Unexpected replay'
                    finally:stop(process)
        print(f'PASS: {server.calls} independent reader failures; fixed reasons cross JSON/SSE/native, no provider payload logs, unknown ledger and no replay',flush=True)
    finally:server.shutdown();server.server_close();worker.join(10)

if __name__=='__main__':main()
