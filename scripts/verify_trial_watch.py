#!/usr/bin/env python3
"""Synthetic transports plus actual local CodexOne HTTP integration; no external calls."""
import copy
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import time
import unittest
import trial_watch as watch

SAMPLE = dict(ready_status=200,ready_seconds=0.01,containers=[dict(status='running',restarts=0)],
              logs={},upstream={},protocols=[],daily=[dict(atUnixSeconds=0,requests=0,failed=0,failures={})],
              in_flight=0,longest_seconds=0,accounts=[],attention=[])
SECRET = 'synthetic-watch-secret-never-persist'


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.state = self.root/'state'; self.state.mkdir()
        self.fixture = self.root/'fixture.json'; self.fixture.write_text(json.dumps(SAMPLE))
        self.counter = self.root/'rollback-count'
        self.config = dict(transport=['sh','-c'],remote=dict(compose_directory='/<compose-directory>', admin_token_file='/<admin-file>',service='gateway',ready_url='http://127.0.0.1:1/health/ready',admin_base_url='http://127.0.0.1:2'),rollback='echo done >> '+str(self.counter),thresholds={'probe_timeout':0.2})
        # Ignore appended remote command, but consume its stdin exactly like a transport.
        self.config['transport'] = [sys.executable,'-c',
            'import sys; sys.stdin.read(); print(open(sys.argv[1]).read())',str(self.fixture)]
    def sample(self, **changes):
        value = copy.deepcopy(SAMPLE); value.update(changes)
        self.fixture.write_text(json.dumps(value)); return value
    def check(self): return watch.check(self.config,self.state)
    def summary(self, since=None):
        output = io.StringIO()
        with redirect_stdout(output): code = watch.summary(self.state,since)
        self.assertLessEqual(len(output.getvalue().splitlines()),25)
        return code, output.getvalue()
    def test_capacity_boundary_is_critical_without_automatic_rollback(self):
        self.sample(headroom=[dict(metric='daily_requests',percent=79.99)])
        self.assertEqual(self.check()['status'],'ok')
        self.sample(headroom=[dict(metric='daily_requests',percent=80)])
        row = self.check()
        self.assertEqual(row['status'],'critical')
        self.assertFalse(row['hard_fault'])
        self.assertEqual(self.cli_loop(self.config).returncode,0)
        self.assertFalse(self.counter.exists())
    def test_normal_and_summary(self):
        self.assertEqual(self.summary()[0],3)
        self.assertEqual(self.check()['status'],'ok'); self.assertEqual(self.summary()[0],0)
        self.sample(protocols=['new_control']); self.assertEqual(self.check()['status'],'warn')
        self.assertEqual(self.summary()[0],1)
        self.sample(accounts=[dict(authorization='requires_auth',quota_percent=0)])
        self.assertEqual(self.check()['status'],'critical'); self.assertEqual(self.summary()[0],2)
    def test_failure_boundaries_and_late_settlement(self):
        self.check()
        self.sample(daily=[dict(atUnixSeconds=0,requests=19,failed=2,failures={'upstream_rejected':2,'client_cancelled':1})])
        row = self.check(); self.assertEqual(row['status'],'warn'); self.assertNotIn('client_cancelled',row['failures'])
        self.sample(daily=[dict(atUnixSeconds=0,requests=39,failed=4,failures={'upstream_rejected':4})])
        self.assertEqual(self.check()['status'],'critical')
        self.sample(daily=[dict(atUnixSeconds=0,requests=59,failed=5,failures={'upstream_rejected':5})])
        self.assertEqual(self.check()['status'],'warn')
    def cli_loop(self, config):
        path = self.root/'config.json'; path.write_text(json.dumps(config))
        return subprocess.run([sys.executable,str(Path(watch.__file__)),'loop','--config',str(path),
            '--state',str(self.state),'--interval','0.01','--duration','0.0003','--auto-rollback'],capture_output=True,timeout=8)
    def test_auto_rollback_once(self):
        self.sample(ready_status=503)
        # transport executes fixture output for probes and shell rollback verbatim.
        wrapper = self.root/'transport.py'
        wrapper.write_text('import sys,subprocess\nif sys.argv[1].startswith("python3 -"):\n sys.stdin.read(); print(open('+repr(str(self.fixture))+').read())\nelse: sys.exit(subprocess.call(sys.argv[1],shell=True))\n')
        self.config['transport'] = [sys.executable,str(wrapper)]
        result = self.cli_loop(self.config); self.assertEqual(result.returncode,2,result.stderr)
        self.assertEqual(self.counter.read_text().splitlines(),['done'])
        self.assertEqual(len((self.state/'history.jsonl').read_text().splitlines()),3)
        self.assertEqual(self.cli_loop(self.config).returncode,2)
        self.assertEqual(self.counter.read_text().splitlines(),['done'])
        self.assertEqual(self.summary()[0],2)
    def test_existing_marker_and_failed_rollback(self):
        watch.atomic(self.state/'ROLLED_BACK',{'exit_code':None})
        watch.rollback(self.config,self.state,'test'); self.assertFalse(self.counter.exists())
    def test_probe_failure_and_timeout_never_rollback(self):
        for code in ('import sys;sys.exit(7)','import time;time.sleep(5)'):
            self.config['transport'] = [sys.executable,'-c',code]
            self.assertEqual(self.cli_loop(self.config).returncode,0)
            self.assertFalse((self.state/'ROLLED_BACK').exists())
        rows = [json.loads(x) for x in (self.state/'history.jsonl').read_text().splitlines()]
        self.assertTrue(all(r['reasons']==['probe_failed'] for r in rows))
    def test_container_and_probe_breaks_streak(self):
        self.sample(containers=[])
        self.assertFalse(self.check()['hard_fault']); self.check()
        self.assertTrue(self.check()['hard_fault'])
        self.config['transport'] = ['false']; self.check()
        self.assertEqual(watch.load(self.state/'state.json',{})['container_failures'],0)
    def test_attention_and_secret(self):
        self.sample(extra_secret=SECRET,attention=[dict(kind='storage_pressure',severity='critical',subject='system',detail=SECRET)])
        row = self.check(); self.assertEqual(row['status'],'critical')
        self.assertNotIn(SECRET,json.dumps(row)); self.assertNotIn(SECRET,self.summary()[1])
        configpath = self.root/'private-config.json'; configpath.write_text(json.dumps(self.config))
        output = subprocess.run([sys.executable,str(Path(watch.__file__)),'check','--config',str(configpath),
            '--state',str(self.state)],capture_output=True,timeout=3)
        self.assertEqual(output.returncode,2)
        self.assertNotIn(SECRET.encode(),output.stdout+output.stderr)
        for path in self.state.iterdir(): self.assertNotIn(SECRET,path.read_text())
    def test_threshold_signals_and_midnight(self):
        self.check()
        self.sample(logs={'critical':1},containers=[dict(status='running',restarts=1)],
                    accounts=[dict(authorization='ready',quota_percent=95)],longest_seconds=7201,
                    daily=[dict(atUnixSeconds=86400,requests=20,failed=2,failures={'rate_limited':2})])
        row = self.check()
        self.assertEqual(row['status'],'critical')
        self.assertTrue({'container_restarted','critical_logs','quota_high','long_request'}.issubset(row['reasons']))
        self.assertEqual(row['admitted'],20)
    def test_signals_stop_loop(self):
        configpath = self.root/'config.json'; configpath.write_text(json.dumps(self.config))
        for sig in (signal.SIGTERM,signal.SIGINT):
            process = subprocess.Popen([sys.executable,str(Path(watch.__file__)),'loop','--config',str(configpath),
                '--state',str(self.state),'--interval','30','--duration','1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                time.sleep(0.15); process.send_signal(sig)
                out,err = process.communicate(timeout=3)
                self.assertEqual(process.returncode,0,err)
            finally:
                if process.poll() is None: process.kill(); process.wait()
    def test_management_failure_preserves_hard_fault_evidence(self):
        self.sample(ready_status=0,sources_unavailable=['usage','accounts'])
        for _ in range(3): row = self.check()
        self.assertTrue(row['hard_fault']); self.assertIn('management_unavailable',row['reasons'])

    def test_invalid_thresholds(self):
        for thresholds in ({'ready_failures':0},{'ready_failures':1.5},{'probe_timeout':float('nan')}, {'failure_warn':2}):
            config = copy.deepcopy(self.config); config['thresholds'] = thresholds
            with self.assertRaises(ValueError): watch.validate(config)
    def test_failed_rollback_is_not_retried(self):
        self.config['transport'] = ['sh','-c']; self.config['rollback'] = 'exit 7'
        self.assertEqual(watch.rollback(self.config,self.state,'synthetic failure')['exit_code'],7)
        self.config['rollback'] = 'exit 0'
        self.assertEqual(watch.rollback(self.config,self.state,'retry')['exit_code'],7)
    def test_real_remote_program(self):
        from verify_admin import running_admin
        from verify_keys import ADMIN
        binary = Path(__file__).resolve().parents[1]/'.build/debug/codexone'
        self.assertTrue(binary.exists(),'Build codexone before running this entry')
        with running_admin(str(binary),account_master=True) as fixture:
            # Fake Docker only: real probe script, credential file and gateway HTTP.
            binpath = self.root/'bin'; binpath.mkdir(); docker = binpath/'docker'
            docker.write_text('#!/bin/sh\ncase "$*" in\n *"ps --all"*) echo synthetic-container;;\n "inspect "*) echo \'[{"State":{"Status":"running"},"RestartCount":0}]\';;\n *"logs "*) :;;\n *) exit 1;;\nesac\n'); docker.chmod(0o700)
            remote = dict(compose_directory=str(self.root),service='gateway',admin_token_file=str(fixture.admin),
                ready_url=f'http://127.0.0.1:{fixture.ports["data"]}/health/ready',
                admin_base_url=f'http://127.0.0.1:{fixture.ports["admin"]}')
            config = dict(transport=['env','PATH='+str(binpath)+':'+__import__('os').environ['PATH'],'sh','-c'],remote=remote,rollback='exit 0')
            row = watch.check(config,self.state)
            self.assertEqual(row['status'],'warn',row)
            self.assertEqual([x['kind'] for x in row['attention']],['backup_disabled'])
            self.assertTrue(any(x['metric']=='detail_rows' for x in row['headroom']))
            self.assertEqual(fixture.provider.calls,0)
            for path in self.state.iterdir(): self.assertNotIn(ADMIN,path.read_text())
    def test_remote_attention_present(self):
        binpath = self.root/'bin'; binpath.mkdir(); docker = binpath/'docker'
        docker.write_text('#!/bin/sh\ncase "$*" in\n *"ps --all"*) echo synthetic-container;;\n "inspect "*) echo \'[{"State":{"Status":"running"},"RestartCount":0}]\';;\n *"logs "*) :;;\n *) exit 1;;\nesac\n'); docker.chmod(0o700)
        docker.write_text(docker.read_text().replace('*\"logs \"*) :;;', '*\"logs \"*) echo \'warning Client protocol extension protocol_name=future.control '+SECRET+'\';;'))
        remote = dict(compose_directory=str(self.root),service='gateway')
        config = dict(transport=['env','PATH='+str(binpath)+':'+__import__('os').environ['PATH'],'sh','-c'],remote=remote,rollback='exit 0')
        # Real remote program with attention present via synthetic HTTP server.
        from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
        import threading
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                payload = ({'accounts':[]} if self.path=='/api/accounts' else
                    {'buckets':[]} if self.path.startswith('/api/usage/daily') else
                    {'rows':[]} if self.path.startswith('/api/usage/in-flight') else
                    {'items':[dict(kind='quota_high',severity='warning',subjectType='account',subjectName=SECRET)]} if self.path=='/api/attention' else {})
                self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(payload).encode())
        server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        try:
            token = self.root/'admin'; token.write_text(SECRET)
            remote.update(admin_token_file=str(token),admin_base_url=f'http://127.0.0.1:{server.server_port}',ready_url=f'http://127.0.0.1:{server.server_port}/health/ready')
            row = watch.check(config,self.state)
            self.assertEqual(row['status'],'warn'); self.assertEqual(row['attention'][0]['subject'],'account')
            self.assertEqual(row['protocols'],['future.control'])
            self.assertNotIn(SECRET,json.dumps(row))
        finally: server.shutdown(); server.server_close(); thread.join()


if __name__ == '__main__': unittest.main(verbosity=2)
