#!/usr/bin/env python3
"""Source policy conversion boundaries, using only a synthetic SQLite source."""
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
from export_key_trial import COLUMNS, convert, write_private
from verify_keys import LIMITS


def main():
    with tempfile.TemporaryDirectory(prefix='codexone-key-export-') as temporary:
        root=Path(temporary);path=root/'source.sqlite'
        row={key:None for key in COLUMNS}
        row.update(id='synthetic-source-key',name='synthetic-selected',key_hash=hashlib.sha256(b'synthetic source key').hexdigest(),
            key_prefix='synthetic',is_active=1,traffic_class='foreground',
            account_assignment_scope_enabled=0,source_assignment_scope_enabled=0,apply_to_codex_model=0)
        approval=dict(models=['synthetic-text'],limits=LIMITS,selectedName='synthetic-selected')
        columns=sorted(COLUMNS)
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE api_keys ('+','.join(columns)+')')
            def insert(value):db.execute('INSERT INTO api_keys VALUES('+','.join('?' for _ in columns)+')',[value[k] for k in columns])
            insert(row)
            for n,changes in enumerate([dict(is_active=0),dict(expires_at='2099-01-01'),dict(enforced_model='synthetic-text'),
                dict(account_assignment_scope_enabled=1),dict(allowed_reasoning_efforts='["low"]'),
                dict(allowed_models='["other"]'),dict(allowed_models='null'),dict(transport_policy_override='http'),dict(traffic_class='background')]):
                r={**row,**changes,'id':f'synthetic-rejected-{n}','name':'synthetic-other'}
                insert(r)
        before=path.read_bytes();result=convert(path,approval)
        assert path.read_bytes()==before
        assert len(result['manifest']['entries'])==1 and len(result['quarantine'])==9
        assert result['manifest']['entries'][0]['policy']['models']==['synthetic-text']
        assert result['mapping']['selectedKeyID']==result['manifest']['entries'][0]['id']
        assert 'digest' not in json.dumps(result['mapping'])+json.dumps(result['quarantine'])
        output=root/'output';write_private(result,output)
        assert output.stat().st_mode&0o077==0 and all(p.stat().st_mode&0o077==0 for p in output.iterdir())
        try:write_private(result,output)
        except FileExistsError:pass
        else:raise AssertionError('Existing export was overwritten')
        with sqlite3.connect(path) as db:db.execute('ALTER TABLE api_keys ADD COLUMN unknown_policy')
        try:convert(path,approval)
        except AssertionError:pass
        else:raise AssertionError('Unknown source policy was ignored')
    print('PASS: read-only schema-pinned export, selected-Key mapping, conservative model policy, source-policy quarantine and private exclusive files')


if __name__=='__main__':main()
