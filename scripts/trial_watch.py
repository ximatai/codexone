#!/usr/bin/env python3
"""Private, aggregate-only trial monitoring. Python 3 standard library on both ends."""
import argparse
from collections import Counter
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import math
import urllib.parse
import ipaddress

# This fixed program receives only configuration and a timestamp, never a secret.
REMOTE = r'''
import collections, json, pathlib, re, subprocess, sys, time, urllib.request, urllib.error
c = CONFIG; r = c['remote']; now = int(time.time())
secret = pathlib.Path(r['admin_token_file']).read_text().strip()
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args): return None
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
def get(url, auth=False):
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + secret} if auth else {})
    try:
        with opener.open(req, timeout=8) as response:
            body = response.read(1048577)
            if len(body) > 1048576: raise ValueError('oversize')
            return response.status, json.loads(body) if auth else {}
    except urllib.error.HTTPError as e: return e.code, {}
unavailable = set()
def api(path, optional=False):
    try:
        status, body = get(r['admin_base_url'].rstrip('/') + path, True)
        if optional and status == 404: return {}
        if status == 200:
            expected = ('quota' if path.endswith('/observation') else 'accounts' if path.startswith('/api/accounts')
                else 'buckets' if path.startswith('/api/usage/daily') else 'rows' if path.startswith('/api/usage/in-flight') else 'items')
            if expected in body: return body
    except Exception: pass
    unavailable.add(path.split('?')[0].split('/')[2])
    return {}
def command(args):
    return subprocess.run(args, cwd=r['compose_directory'], capture_output=True, timeout=15, check=True).stdout.decode()
begin = time.monotonic()
try: ready, _ = get(r['ready_url'])
except Exception: ready = 0
elapsed = time.monotonic() - begin
ids = command(['docker','compose','ps','--all','--quiet',r['service']]).split()
containers = []
for ident in ids:
    value = json.loads(command(['docker','inspect',ident]))[0]
    containers.append({'status':value['State']['Status'], 'restarts':value['RestartCount']})
logs = command(['docker','compose','logs','--no-color','--no-log-prefix','--since',str(c['since']), '--until',str(now),r['service']])
levels = collections.Counter(); upstream = collections.Counter(); protocols = set()
for line in logs.splitlines():
    level = re.search(r'\b(trace|debug|info|notice|warning|error|critical)\b',line,re.I)
    if level: levels[level[1].lower()] += 1
    if 'Client protocol extension' in line:
        match = re.search(r'protocol_name[=:]\s*"?([A-Za-z0-9_.-]{1,128})',line)
        if match and secret not in match[1]: protocols.add(match[1])
    # Only explicitly upstream-labelled numeric statuses, not arbitrary log numbers.
    for status in re.findall(r'upstream_status[=:]\s*"?(401|403|429|5\d\d)\b',line):
        upstream[status if not status.startswith('5') else '5xx'] += 1
accounts = []; after = ''
for page in range(64):
    body = api('/api/accounts' + ('?after='+after if after else ''))
    for a in body.get('accounts', []):
        observation = api('/api/accounts/'+a['id']+'/observation')
        percentages = []
        for limit in observation.get('quota', {}).get('limits', []):
            for key in ('primary','secondary'):
                w = limit.get(key)
                if w and w.get('usedPercent') is not None: percentages.append(w['usedPercent'])
        accounts.append({'authorization':a['authorization'], 'quota_percent':max(percentages,default=0)})
    after = body.get('nextCursor')
    if not after: break
else: raise ValueError('pagination')
daily = api('/api/usage/daily?days=31').get('buckets', [])
inflight = api('/api/usage/in-flight?limit=200').get('rows', [])
attention = api('/api/attention', True).get('items', [])
# Subject names and IDs may be user text; retain subject type only.
items = [{'kind':a['kind'], 'severity':a['severity'], 'subject':a.get('subjectType','system')} for a in attention]
result = {'observed_at':now,'ready_status':ready,'ready_seconds':elapsed,'containers':containers,'logs':dict(levels),
'upstream':dict(upstream),'protocols':sorted(protocols),'daily':daily,
'in_flight':len(inflight),'longest_seconds':max((a['elapsedSeconds'] for a in inflight),default=0),
'accounts':accounts,'attention':items,'sources_unavailable':sorted(unavailable)}
output = json.dumps(result,separators=(',',':'))
if secret and secret in output: raise ValueError('unsafe')
print(output)
'''
DEFAULTS = dict(failure_critical=0.10, failure_warn=0.05, minimum_admitted=20,
                longest_seconds=7200, quota_percent=95, ready_failures=3,
                container_failures=3, probe_timeout=90)


def atomic(path, value):
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, separators=(',', ':')); stream.write('\n')
            stream.flush(); os.fsync(stream.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        if os.path.exists(name): os.unlink(name)


@contextmanager
def locked(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (directory / '.lock').open('a') as stream:
        os.chmod(stream.name, 0o600)
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def load(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def run(command, timeout, data=None):
    # Kill the whole transport process group, including a local sh child on timeout.
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        payload, _ = process.communicate(data, timeout=timeout)
    except BaseException:
        os.killpg(process.pid, signal.SIGKILL); process.wait(); raise
    if len(payload) > 2 * 1024 * 1024: raise ValueError('oversize')
    return process.returncode, payload


def probe(config, since, timeout):
    payload = json.dumps(dict(remote=config['remote'], since=since)) + '\n'
    script = 'import json\nCONFIG = json.loads(' + repr(payload) + ')\n' + REMOTE
    code, output = run(config['transport'] + ['python3 -'], timeout, script.encode())
    if code: raise ValueError('transport')
    return json.loads(output)


def safe_name(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', value):
        raise ValueError('name')
    return value


def sanitized(raw):
    # Reconstruct the schema: never persist arbitrary transport fields or error text.
    def number(value):
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not 0 <= value <= 1e15:
            raise ValueError('number')
        return value
    def counts(value): return {safe_name(k): number(v) for k, v in value.items()}
    return dict(observed_at=number(raw.get('observed_at',int(time.time()))), sources_unavailable=[safe_name(s) for s in raw.get('sources_unavailable',[])],
        ready_status=number(raw['ready_status']), ready_seconds=number(raw['ready_seconds']),
        containers=[dict(status=safe_name(c['status']), restarts=number(c['restarts'])) for c in raw['containers']],
        logs=counts(raw['logs']), upstream=counts(raw['upstream']),
        protocols=sorted(set(safe_name(p) for p in raw['protocols'])),
        daily=[dict(atUnixSeconds=number(b['atUnixSeconds']), requests=number(b['requests']),
                    failed=number(b['failed']), failures=counts(b['failures'])) for b in raw['daily']],
        in_flight=number(raw['in_flight']), longest_seconds=number(raw['longest_seconds']),
        accounts=[dict(authorization=safe_name(a['authorization']),quota_percent=number(a['quota_percent'])) for a in raw['accounts']],
        attention=[{k:safe_name(a[k]) for k in ('kind','severity','subject')} for a in raw.get('attention',[])])


def rollback(config, directory, reason):
    marker = directory / 'ROLLED_BACK'
    if marker.exists(): return load(marker, {})
    # Persist intent first: a crash/timeout is unknown, never safe to retry automatically.
    result = dict(at=int(time.time()), reason=reason, exit_code=None)
    atomic(marker, result)
    try:
        result['exit_code'], _ = run(config['transport'] + [config['rollback']],
                                    config.get('thresholds', {}).get('probe_timeout',90))
    except Exception: result['exit_code'] = -1
    atomic(marker, result)
    return result


def check(config, directory):
    state = load(directory/'state.json', {})
    now = int(time.time()); t = DEFAULTS | config.get('thresholds', {})
    reasons = []; severity = 0
    def flag(reason, level=1):
        nonlocal severity
        reasons.append(reason); severity = max(severity, level)
    result = dict(at=now, admitted=0, failed=0, failures={}, new_protocols=[])
    try:
        data = sanitized(probe(config, state.get('last_probe', now), t['probe_timeout']))
    except Exception:
        flag('probe_failed', 2)
        state['probe_failures'] = state.get('probe_failures',0)+1
        state['ready_failures'] = state['container_failures'] = 0
    else:
        result.update(data); state['probe_failures'] = 0
        if data['sources_unavailable']: flag('management_unavailable')
        state['ready_failures'] = state.get('ready_failures',0)+1 if data['ready_status'] != 200 else 0
        bad = not data['containers'] or any(c['status'] != 'running' for c in data['containers'])
        state['container_failures'] = state.get('container_failures',0)+1 if bad else 0
        if state['ready_failures']: flag('ready_failed', 2 if state['ready_failures'] >= t['ready_failures'] else 1)
        if bad: flag('container_not_running', 2 if state['container_failures'] >= t['container_failures'] else 1)
        result['hard_fault'] = state['ready_failures'] >= t['ready_failures'] or state['container_failures'] >= t['container_failures']
        restarts = sum(c['restarts'] for c in data['containers'])
        if restarts > state.get('restarts',restarts): flag('container_restarted')
        state['restarts'] = restarts
        old = {b['atUnixSeconds']:b for b in state.get('daily',[])}
        failures = Counter()
        if 'daily' in state and 'usage' not in data['sources_unavailable']:
            for b in data['daily']:
                previous = old.get(b['atUnixSeconds'], {})
                result['admitted'] += max(0,b['requests']-previous.get('requests',0))
                result['failed'] += max(0,b['failed']-previous.get('failed',0))
                for k,v in b['failures'].items():
                    if k != 'client_cancelled': failures[k] += max(0,v-previous.get('failures',{}).get(k,0))
        result['failures'] = dict(failures)
        # daily.failed already excludes client cancellations (U10).
        rate = result['failed']/result['admitted'] if result['admitted'] else 0
        if result['admitted'] >= t['minimum_admitted'] and rate >= t['failure_critical']: flag('failure_rate_critical',2)
        elif rate >= t['failure_warn']: flag('failure_rate_warn')
        if data['longest_seconds'] > t['longest_seconds']: flag('long_request')
        if any(a['authorization'] in ('requires_auth','auth_uncertain') for a in data['accounts']): flag('account_auth',2)
        if any(a['quota_percent'] >= t['quota_percent'] for a in data['accounts']): flag('quota_high')
        if data['logs'].get('critical',0): flag('critical_logs')
        result['new_protocols'] = sorted(set(data['protocols'])-set(state.get('protocols',[])))
        if result['new_protocols']: flag('new_protocol')
        for a in data['attention']: flag('attention_'+a['kind'],2 if a['severity']=='critical' else 1)
        state['protocols'] = sorted(set(state.get('protocols',[])) | set(data['protocols']))
        if 'usage' not in data['sources_unavailable']: state['daily'] = data['daily']
        state['last_probe'] = data['observed_at']
        result['upstream_classifications'] = {k:failures.get(k,0) for k in
            ('authentication_rejected','rate_limited','upstream_unavailable','upstream_rejected')}
    result['status'] = ('ok','warn','critical')[severity]; result['reasons'] = sorted(set(reasons))
    state['last_check'] = now
    # Daily snapshots are state only; history retains interval aggregates.
    result.pop('daily',None)
    with (directory/'history.jsonl').open('ab+') as stream:
        os.chmod(stream.name,0o600)
        stream.seek(0,os.SEEK_END)
        if stream.tell():
            stream.seek(-1,os.SEEK_END)
            if stream.read(1) != b'\n': stream.write(b'\n')
        stream.write((json.dumps(result,separators=(',',':'))+'\n').encode())
        stream.flush(); os.fsync(stream.fileno())
    atomic(directory/'state.json',state)
    return result


def summary(directory, since=None):
    path = directory/'history.jsonl'
    rows = []
    if path.exists():
        with path.open() as stream:
            for line in stream:
                try: row = json.loads(line)
                except ValueError: continue  # interrupted final append
                if since is None or row['at'] >= time.time()-since*3600: rows.append(row)
    rolled = (directory/'ROLLED_BACK').exists()
    if not rows:
        print('critical: rolled back' if rolled else 'no data'); return 2 if rolled else 3
    severity = max((('ok','warn','critical').index(r['status']) for r in rows),default=0)
    code = 2 if rolled else severity
    reasons = Counter(x for r in rows for x in r['reasons'])
    admitted = sum(r['admitted'] for r in rows); failed = sum(r['failed'] for r in rows)
    print(('ok','warn','critical')[code]+f' | checks={len(rows)}')
    print(f"latest: {rows[-1]['at']} {rows[-1]['status']}")
    print(f"warn={sum(r['status']=='warn' for r in rows)} critical={sum(r['status']=='critical' for r in rows)}")
    print('reasons: '+json.dumps(dict(reasons),separators=(',',':')))
    print(f'requests={admitted} failed={failed} rate={failed/admitted if admitted else 0:.2%}')
    print('failures: '+json.dumps(dict(sum((Counter(r['failures']) for r in rows),Counter()))))
    print(f"in-flight peak={max(r.get('in_flight',0) for r in rows)} longest_seconds={max(r.get('longest_seconds',0) for r in rows)}")
    print('new protocols: '+json.dumps(sorted({p for r in rows for p in r['new_protocols']})))
    observed_accounts = next((r['accounts'] for r in reversed(rows) if 'accounts' in r and 'accounts' not in r.get('sources_unavailable',[])),None)
    print('accounts (last observed): '+json.dumps(observed_accounts,separators=(',',':')))
    print('rolled_back: '+str(rolled).lower())
    return code


def validate(config):
    transport = config['transport']
    if not isinstance(transport,list) or not transport or not all(isinstance(s,str) and s for s in transport):
        raise ValueError('transport')
    if not isinstance(config['rollback'],str) or not config['rollback']: raise ValueError('rollback')
    remote = config['remote']
    for key in ('compose_directory','admin_token_file'):
        if not Path(remote[key]).is_absolute(): raise ValueError('remote path')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+',remote['service']) or remote['service'].startswith('-'):
        raise ValueError('service')
    for key in ('ready_url','admin_base_url'):
        url = urllib.parse.urlsplit(remote[key])
        if url.scheme not in ('http','https') or url.username or url.password or url.query or url.fragment:
            raise ValueError('url')
        if url.hostname != 'localhost' and not ipaddress.ip_address(url.hostname).is_loopback:
            raise ValueError('loopback required')
    thresholds = config.get('thresholds',{})
    if set(thresholds)-set(DEFAULTS): raise ValueError('threshold')
    for key,value in thresholds.items():
        if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or value <= 0:
            raise ValueError('threshold')
        if key in ('minimum_admitted','ready_failures','container_failures') and int(value) != value:
            raise ValueError('threshold integer')
        if key.startswith('failure_') and value > 1: raise ValueError('ratio')
    t = DEFAULTS | thresholds
    if t['failure_warn'] > t['failure_critical']: raise ValueError('threshold ordering')


def main():
    parser = argparse.ArgumentParser(description=__doc__); sub = parser.add_subparsers(dest='command',required=True)
    for name in ('check','loop','rollback','summary'):
        p = sub.add_parser(name); p.add_argument('--state',type=Path,required=True)
        if name != 'summary': p.add_argument('--config',type=Path,required=True)
        if name == 'summary': p.add_argument('--since',type=float)
        if name == 'rollback': p.add_argument('--reason',required=True)
        if name == 'loop':
            p.add_argument('--interval',type=float,required=True)
            limit = p.add_mutually_exclusive_group(required=True)
            limit.add_argument('--until',type=float); limit.add_argument('--duration',type=float)
            p.add_argument('--auto-rollback',action='store_true')
    args = parser.parse_args()
    if args.command == 'summary': return summary(args.state,args.since)
    config = load(args.config,{})
    validate(config)
    with locked(args.state):
        if args.command == 'rollback':
            rollback(config,args.state,args.reason); return 2
        if args.command == 'check':
            result = check(config,args.state); print(json.dumps(result,separators=(',',':')))
            return ('ok','warn','critical').index(result['status'])
        if not math.isfinite(args.interval) or args.interval <= 0: raise ValueError('interval')
        stop = False
        def terminate(*_):
            nonlocal stop
            stop = True
        signal.signal(signal.SIGINT,terminate); signal.signal(signal.SIGTERM,terminate)
        end = args.until if args.until is not None else time.time()+args.duration*3600
        if not math.isfinite(end): raise ValueError('end')
        while not stop and time.time() < end:
            if (args.state/'ROLLED_BACK').exists(): return 2
            result = check(config,args.state)
            if args.auto_rollback and result.get('hard_fault'):
                rollback(config,args.state,','.join(result['reasons'])); return 2
            deadline = min(end,time.time()+args.interval)
            while not stop and time.time() < deadline: time.sleep(max(0,min(0.2,deadline-time.time())))
        return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except (Exception, KeyboardInterrupt):
        print('trial_watch: operation failed (details suppressed)',file=sys.stderr); sys.exit(3)
