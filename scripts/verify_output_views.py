#!/usr/bin/env python3
"""Independent ordinary-output views over real sockets; no credentials or model calls."""
import argparse
import copy
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from verify_protocol import TOKEN, start, stop
from verify_text_contract import Provider as WireProvider, FIXTURE, PRIVATE, call, rows, outcomes

GOOD = ['message', 'unicode', 'prefix', 'sparse-done', 'metadata', 'two-items', 'function', 'custom',
        'reasoning', 'reasoning-omitted', 'refusal', 'progress', 'created-prefix']
FINAL = ['final-id', 'final-text', 'final-missing', 'final-reorder', 'final-type', 'tool-call', 'tool-name',
         'tool-namespace', 'tool-arguments', 'custom-input', 'reasoning-summary', 'reasoning-cipher',
         'duplicate-id', 'duplicate-call']
EARLY = ['early-index', 'early-type', 'delta-text', 'late-delta', 'part-type', 'part-index', 'duplicate-index', 'part-missing', 'item-id-type', 'tool-delta-call', 'created-id']


def tools():
    functions = [dict(type='function', name=name, parameters=dict(type='object', properties={}))
                 for name in ('lookup', 'other')]
    return [dict(type='namespace', name=space, tools=functions) for space in ('box', 'other')] + [
        dict(type='custom', name='synthetic_custom', format=dict(type='text'))]


class Provider(WireProvider):
    def sequence(self, request):
        assert request['model'] == 'synthetic-contract' and self.headers.get('Authorization') is None
        with self.server.guard:
            self.server.calls += 1
            index = self.server.calls
        events = json.loads(self.server.literal.replace('resp_contract_1', f'resp_contract_{index}')
                            .replace('msg_contract_1', f'msg_contract_{index}'))
        result = events[-1]['response']
        mode = self.server.mode
        if len(request['input']) > 1:
            assert any(x.get('role') == 'assistant' or x.get('type') in ('function_call', 'custom_tool_call', 'reasoning')
                       for x in request['input']), 'Missing previous output window'
        kind = 'function_call' if mode.startswith('tool-') or mode in ('function', 'duplicate-call') else (
            'custom_tool_call' if mode in ('custom', 'custom-input') else 'reasoning' if mode.startswith('reasoning') else 'message')
        item = result['output'][0]
        if kind in ('function_call', 'custom_tool_call'):
            item = dict(type=kind, id=f'item_{index}', status='completed', call_id=f'call_{index}',
                        name='lookup' if kind == 'function_call' else 'synthetic_custom')
            field = 'arguments' if kind == 'function_call' else 'input'
            item[field] = '{"synthetic":1}'
            if kind == 'function_call': item['namespace'] = 'box'
            added = {**item, field: '', 'status': 'in_progress'}
            prefix = 'response.function_call_arguments' if kind == 'function_call' else 'response.custom_tool_call_input'
            events = [events[0], dict(type='response.output_item.added', output_index=0, item=added),
                      dict(type=prefix+'.delta', item_id=item['id'], output_index=0, delta=item[field][:3]),
                      dict(type=prefix+'.delta', item_id=item['id'], output_index=0, delta=item[field][3:]),
                      dict(type=prefix+'.done', item_id=item['id'], output_index=0, **{field: item[field]}),
                      dict(type='response.output_item.done', output_index=0, item=copy.deepcopy(item)), events[-1]]
        elif kind == 'reasoning':
            item = dict(type='reasoning', id=f'item_{index}', status='completed', summary=[dict(type='summary_text', text='synthetic summary')],
                        content=[dict(type='reasoning_text', text=PRIVATE)], encrypted_content='synthetic-private-cipher-'+str(index))
            added = {**item, 'summary': [], 'content': [], 'status': 'in_progress'}
            added.pop('encrypted_content')
            events = [events[0], dict(type='response.output_item.added', output_index=0, item=added),
                      dict(type='response.reasoning_text.delta', item_id=item['id'], content_index=0, output_index=0, delta=PRIVATE),
                      dict(type='response.reasoning_text.done', item_id=item['id'], content_index=0, text=PRIVATE),
                      dict(type='response.reasoning_summary_text.delta', item_id=item['id'], summary_index=0, delta='synthetic summary'),
                      dict(type='response.reasoning_summary_text.done', item_id=item['id'], summary_index=0, text='synthetic summary'),
                      dict(type='response.output_item.done', output_index=0, item=copy.deepcopy(item)), events[-1]]
        result['output'] = [copy.deepcopy(item)]
        if mode == 'progress':
            events.insert(3, dict(type='response.in_progress', response={**copy.deepcopy(result), 'status': 'in_progress', 'usage': None}))
        if mode == 'created-prefix':
            events[0]['response']['output'] = [copy.deepcopy(events[1]['item'])]
            events[0]['response']['output'][0]['content'] = [dict(type='output_text', text=PRIVATE[:10])]
            events[1]['item']['content'] = [dict(type='output_text', text=PRIVATE[:10])]
            events[2]['delta'] = PRIVATE[10:]
        if mode == 'unicode':
            text = '合成🙂e\u0301'
            events[2]['delta'] = text
            events[-2]['item']['content'][0]['text'] = text
            result['output'][0]['content'][0]['text'] = text
        if mode == 'prefix':
            events[1]['item']['content'] = [dict(type='output_text', text=PRIVATE[:10])]
            events[2]['delta'] = PRIVATE[10:]
        if mode == 'refusal':
            part = dict(type='refusal', refusal='synthetic refusal')
            events[2] = dict(type='response.refusal.delta', item_id=item['id'], content_index=0, delta=part['refusal'])
            events[-2]['item']['content'] = [part]
            result['output'][0]['content'] = [part]
        if mode == 'sparse-done': events = [events[0], events[-2], events[-1]]
        if mode == 'metadata':
            events[1]['item']['phase'] = None
            events[-2]['item']['phase'] = 'final_answer'
            result['output'][0].pop('status')
            result['output'][0]['content'][0]['logprobs'] = None
        if mode in ('two-items', 'final-reorder', 'duplicate-id', 'duplicate-call'):
            second = copy.deepcopy(item);second['id'] = f'synthetic-second-{index}'
            if kind == 'function_call': second['call_id'] = f'synthetic-second-call-{index}'
            result['output'].append(second)
            events.insert(-1, dict(type='response.output_item.done', output_index=1, item=copy.deepcopy(second)))
        target = result['output'][0]
        if mode == 'reasoning-omitted': target.pop('content')
        if mode == 'final-id': target['id'] = 'synthetic-conflicting-id'
        if mode == 'final-text': target['content'][0]['text'] = 'synthetic conflicting final text'
        if mode == 'final-missing': result['output'] = []
        if mode == 'final-reorder': result['output'].reverse()
        if mode == 'final-type':
            result['output'] = [dict(type='reasoning', id=target['id'], summary=[])]
        if mode == 'tool-call': target['call_id'] = 'synthetic-conflicting-call'
        if mode == 'tool-name': target['name'] = 'other'
        if mode == 'tool-namespace': target['namespace'] = 'other'
        if mode == 'tool-arguments': target['arguments'] = '{"synthetic":2}'
        if mode == 'custom-input': target['input'] = 'synthetic changed input'
        if mode == 'reasoning-summary': target['summary'][0]['text'] = 'synthetic changed summary'
        if mode == 'reasoning-cipher': target['encrypted_content'] = 'synthetic-conflicting-cipher'
        if mode == 'duplicate-id': result['output'][1]['id'] = target['id']
        if mode == 'duplicate-call': result['output'][1]['call_id'] = target['call_id']
        if mode in EARLY:
            if mode == 'part-missing':
                events.insert(-1, dict(type='response.content_part.done', item_id=item['id'], output_index=0))
            if mode == 'item-id-type': events[2]['item_id'] = False
            if mode == 'tool-delta-call': events[2]['call_id'] = 'synthetic-conflicting-call'
            if mode == 'created-id':
                events[0]['response']['output'] = [copy.deepcopy(events[1]['item'])]
                events[1]['item']['id'] = 'synthetic-conflicting-id'
            if mode == 'early-index': events[-2]['output_index'] = 1
            if mode == 'early-type': events[2]['type'] = 'response.reasoning_text.delta'
            if mode == 'delta-text': events[2]['delta'] = 'synthetic conflicting delta'
            if mode == 'late-delta': events.insert(-1, copy.deepcopy(events[2]))
            if mode in ('part-type', 'part-index'):
                events.insert(-1, dict(type='response.content_part.done', item_id=item['id'], output_index=0,
                                      content_index=1 if mode == 'part-index' else 0,
                                      part=dict(type='refusal', refusal=PRIVATE) if mode == 'part-type' else dict(type='output_text', text=PRIVATE)))
            if mode == 'duplicate-index':
                second = copy.deepcopy(item);second['id'] = 'synthetic-conflicting-id'
                events.insert(-1, dict(type='response.output_item.done', output_index=0, item=second))
            return events[:-1]  # No later terminal may accidentally create evidence for an early rejection.
        return events


def main():
    parser = argparse.ArgumentParser();parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--case', choices=GOOD+FINAL+EARLY);args=parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1',0), Provider);server.guard=threading.Lock();server.calls=0
    server.literal = json.dumps(json.loads(FIXTURE.read_text())['events'])
    worker=threading.Thread(target=server.serve_forever);worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-output-views-') as temporary:
            for transport in ('http','websocket'):
                before_transport=server.calls
                for case in ([args.case] if args.case else GOOD+FINAL+EARLY):
                    server.mode=case;root=Path(temporary)/(transport+'-'+case);root.mkdir(mode=0o700)
                    config=root/'identity.json';config.write_text(json.dumps(dict(principal='synthetic-contract',keyID='synthetic-key',
                        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),namespace='synthetic-contract',identity='synthetic-identity',
                        models=[dict(id='synthetic-contract',inputMicrosPerMillion=0,outputMicrosPerMillion=0)],reservedMicros=1,
                        upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1',upstreamTransport=transport)));config.chmod(0o600)
                    process,ports=start(str(args.binary.resolve()),config,root);before=server.calls;count=0
                    try:
                        for route in (('sse','json') if transport=='http' else ('sse','json','native')):
                            if transport=='http' and route=='json' and case not in GOOD+['duplicate-id','duplicate-call']:continue
                            request=dict(model='synthetic-contract',input=[dict(role='user',content='synthetic views')],tools=tools())
                            for turn in range(2 if case in GOOD else 1):
                                status,events=call(ports['data'],route,request);count+=1;last=events[-1]
                                if case in GOOD:
                                    assert status==200 and 'error' not in last,(transport,case,route,events)
                                    response=last.get('response',last);request['input']+=response['output']+[dict(role='user',content='synthetic next turn')]
                                else:
                                    expected = 'invalid_upstream_turn' if transport == 'websocket' and case == 'item-id-type' else 'invalid_upstream_output'
                                    assert last.get('error',{}).get('code')==expected,(transport,case,route,events)
                                    assert last['error']['request_id'] in last['error']['message']
                        deadline=time.monotonic()+3
                        while len(rows(root))!=count or any(s=='intent' for s,_,_ in rows(root)):
                            assert time.monotonic()<deadline;time.sleep(.02)
                        process.terminate();process.wait(10);logs=process.stdout.read();records=rows(root)
                        assert server.calls==before+count,'Unexpected replay'
                        if case in EARLY:assert all(s=='unknown' and u is None for s,_,u in records),records
                        else:
                            assert all(s=='settled' and k==('succeeded' if case in GOOD else 'failed') and u['inputTokens']==5 and u['outputTokens']==3 for s,k,u in records),(case,records,outcomes(root))
                        if case not in GOOD and not (transport == 'websocket' and case == 'item-id-type'):assert b'reason=upstream_output_' in logs,logs
                        assert PRIVATE.encode() not in logs and b'synthetic-private-cipher' not in logs and TOKEN.encode() not in logs
                        with sqlite3.connect(root/'state/core.sqlite') as db:
                            assert db.execute("SELECT count(*) FROM bindings WHERE raw_id IN ('synthetic-conflicting-id','synthetic-conflicting-call')").fetchone()[0]==0
                    finally:stop(process)
                print(f'PASS: {transport} {server.calls-before_transport} independent output-view executions; two-turn snapshots, text/tool/reasoning conflicts, exact dispatch and durable evidence',flush=True)
    finally:server.shutdown();server.server_close();worker.join(10)

if __name__=='__main__':main()
