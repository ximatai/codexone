#!/usr/bin/env python3
"""Read-only, schema-pinned CodexLB key conversion. All output files are private verification material."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import time
from urllib.parse import quote

COLUMNS = {'id','name','key_hash','key_prefix','allowed_models','expires_at','is_active','created_at','last_used_at',
    'enforced_model','enforced_reasoning_effort','enforced_service_tier','account_assignment_scope_enabled',
    'apply_to_codex_model','traffic_class','transport_policy_override','usage_sections',
    'source_assignment_scope_enabled','allowed_reasoning_efforts'}
LIMIT_COLUMNS = {'id','api_key_id','limit_type','limit_window','max_value','current_value','model_filter','reset_at'}
FORCED = ('enforced_model','enforced_reasoning_effort','enforced_service_tier','transport_policy_override','allowed_reasoning_efforts')
SCOPES = ('account_assignment_scope_enabled','source_assignment_scope_enabled','apply_to_codex_model')


def convert(source, approval):
    assert set(approval)=={'models','limits','selectedName'}
    models=approval['models'];limits=approval['limits']
    assert isinstance(models,list) and 1<=len(models)<=32 and len(set(models))==len(models)
    assert all(isinstance(x,str) and 0<len(x.encode())<=128 for x in models)
    assert limits == 'source' or isinstance(limits, dict)
    if limits != 'source':
        assert set(limits)=={'requests','active','unresolved','budgetMicros','unresolvedMicros'}
        assert all(type(n) is int and 1<=n<=10**12 for n in limits.values())
    assert isinstance(approval['selectedName'],str) and 0<len(approval['selectedName'].encode())<=256
    path=Path(source).resolve(strict=True)
    db=sqlite3.connect('file:'+quote(str(path),safe='/')+'?mode=ro',uri=True,timeout=2)
    db.row_factory=sqlite3.Row
    try:
        db.execute('PRAGMA query_only=ON');db.execute('BEGIN')
        assert {row[1] for row in db.execute('PRAGMA table_info(api_keys)')}==COLUMNS,'Unsupported source schema'
        rows=db.execute('SELECT '+','.join(sorted(COLUMNS))+' FROM api_keys ORDER BY id LIMIT 257').fetchall()
        assert 1<=len(rows)<=256
        limited=set()
        if limits == 'source':
            assert {row[1] for row in db.execute('PRAGMA table_info(api_key_limits)')}==LIMIT_COLUMNS,'Unsupported source limits schema'
            # Read only the pinned columns in the same source snapshot.
            for record in db.execute('SELECT '+','.join(sorted(LIMIT_COLUMNS))+' FROM api_key_limits'):
                limited.add(record['api_key_id'])
    finally:db.close()
    selected=[row for row in rows if row['name']==approval['selectedName']]
    assert len(selected)==1,'Selected source key is missing or ambiguous'
    entries=[];mapping=[];quarantine=[]
    for row in rows:
        reasons=[]
        if limits == 'source' and row['id'] in limited:reasons.append('source_limits_unsupported')
        digest=row['key_hash'];identifier=row['id']
        assert isinstance(identifier,str) and 0<len(identifier.encode())<=256
        reference=hashlib.sha256(identifier.encode()).hexdigest()[:32]
        new_id='legacy-'+reference
        if row['is_active']!=1:reasons.append('source_inactive')
        if row['expires_at'] is not None:reasons.append('source_expiry_unsupported')
        if any(row[field] is not None for field in FORCED):reasons.append('source_forced_policy_unsupported')
        if any(row[field]!=0 for field in SCOPES):reasons.append('source_assignment_policy_unsupported')
        if row['traffic_class']!='foreground':reasons.append('source_traffic_policy_unsupported')
        if not isinstance(digest,str) or len(digest)!=64 or any(c not in '0123456789abcdef' for c in digest):
            reasons.append('source_digest_invalid')
        allowed=models
        if row['allowed_models'] is not None:
            try:
                raw=row['allowed_models'];assert isinstance(raw,str) and len(raw.encode())<=32768
                values=json.loads(raw)
                assert isinstance(values,list) and len(values)<=32 and all(isinstance(x,str) for x in values)
                allowed=[model for model in models if model in values]
            except (ValueError,TypeError,AssertionError):
                allowed=[];reasons.append('source_models_invalid')
        if not allowed:reasons.append('no_approved_model')
        mapping.append(dict(sourceID=identifier,keyID=new_id,selected=row['name']==approval['selectedName']))
        if reasons:
            quarantine.append(dict(keyID=new_id,reasons=reasons));continue
        entries.append(dict(id=new_id,principal='legacy-p-'+reference,digest=digest,
            policy=dict(models=allowed,limits=({name:None for name in ('requests','active','unresolved','budgetMicros','unresolvedMicros')} if limits == 'source' else limits),visionInput=False,imageGeneration=False,imageModels=[]),
            sourceActive=True,sourceExpiresAtUnixSeconds=None,policyEquivalent=True))
    selected_id=next(m['keyID'] for m in mapping if m['selected'])
    assert any(e['id']==selected_id for e in entries),'Selected key cannot be represented safely'
    assert len({e['digest'] for e in entries})==len(entries)
    return dict(manifest=dict(version=1,capturedAtUnixSeconds=int(time.time()),entries=entries),
        mapping=dict(selectedKeyID=selected_id,entries=mapping),quarantine=quarantine)


def write_private(result, destination):
    destination=Path(destination)
    encoded={name:(json.dumps(value,separators=(',',':'))+'\n').encode() for name,value in result.items()}
    assert all(len(data)<=1048576 for data in encoded.values())
    destination.mkdir(mode=0o700,parents=False,exist_ok=False)
    for name,data in encoded.items():
        fd=os.open(destination/(name+'.json'),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
    fd=os.open(destination,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source-db',required=True)
    parser.add_argument('--approval-file',required=True);parser.add_argument('--output-directory',required=True)
    args=parser.parse_args()
    try:
        # Approval has no credential, but carries the operator's private selection and must stay private.
        fd=os.open(args.approval_file,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)
        with os.fdopen(fd,'rb') as file:
            info=os.fstat(file.fileno())
            assert stat.S_ISREG(info.st_mode) and info.st_uid==os.geteuid() and info.st_nlink==1 and info.st_mode&0o077==0 and 0<info.st_size<=65536
            raw=file.read(65537);assert len(raw)<=65536
        approval=json.loads(raw)
        result=convert(args.source_db,approval);write_private(result,args.output_directory)
        print(json.dumps(dict(importableKeys=len(result['manifest']['entries']),quarantinedKeys=len(result['quarantine']))))
    except Exception:
        raise SystemExit('Private key conversion rejected; inspect source/approval privately; no import was performed.')


if __name__=='__main__':main()
