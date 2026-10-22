#!/usr/bin/env python3
"""Targeted stale-observation and Engine-success/CLI-timeout capacity guard probes."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace

import verify_capacity as capacity


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image',required=True)
    parser.add_argument('--report',type=Path,required=True)
    args=parser.parse_args()
    report=json.loads(args.report.read_text())
    for profile in report['profiles']:
        rows=profile['storage']; now=rows[-1]['sampledUnixSeconds']+1
        capacity.verify_recovery(rows,now)
        for changed,clock in (([row for row in rows if row['phase']!='recovery'],now),
                              (rows,now+10)):
            try:capacity.verify_recovery(changed,clock)
            except AssertionError:pass
            else:raise AssertionError('Stale or missing recovery evidence accepted')
        changed=copy.deepcopy(rows);changed[-1]['criticalQueued']=1
        try:capacity.verify_recovery(changed,now)
        except AssertionError:pass
        else:raise AssertionError('Unsettled recovery queue accepted')
    print('PASS: actual long samples have recovery evidence; missing/stale/queued observations fail')
    original=capacity.run
    for stage in ('volume','initializer'):
        identity={};injected=False
        def fail_after_engine_success(command,ok=True,timeout=35):
            nonlocal injected
            if command[:3]==['docker','volume','create']:
                identity['volume']=command[-1]
                identity['label']=command[command.index('--label')+1]
                if stage=='volume':
                    original(command,ok,timeout);injected=True
                    raise subprocess.TimeoutExpired('synthetic-volume-create',timeout)
            if stage=='initializer' and command[:2]==['docker','run'] and 'CHOWN' in command:
                # Leave an actual initialized-owner container running after losing the CLI result.
                held=command[:2]+['-d']+command[2:]
                held[-1]='sleep 60'
                original(held,ok,timeout);injected=True
                raise subprocess.TimeoutExpired('synthetic-initializer',timeout)
            return original(command,ok,timeout)
        capacity.run=fail_after_engine_success
        try:
            with tempfile.TemporaryDirectory(prefix='codexone-capacity-guard-') as temporary:
                try:
                    capacity.orchestrate(SimpleNamespace(output=Path(temporary)/'result',image=args.image,
                        harness_image='codexone:v8-verification',transport='http',duration=10))
                except subprocess.TimeoutExpired:pass
                else:raise AssertionError('Expected injected CLI failure')
            assert injected
            assert not original(['docker','ps','-aq','--filter','label='+identity['label']]).stdout.strip()
            assert original(['docker','volume','inspect',identity['volume']],ok=False).returncode!=0
            print('PASS: lost '+stage+' result leaves no owned container or volume')
        finally:capacity.run=original


if __name__=='__main__':main()
