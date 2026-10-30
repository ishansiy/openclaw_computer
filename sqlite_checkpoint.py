"""Consistent core-Hermes SQLite checkpoints; active databases always stay local."""
from pathlib import Path
from datetime import datetime,timezone
import os,sys,json,sqlite3,gzip,hashlib,fcntl,time,shutil,argparse,importlib.util,tempfile
os.umask(0o077)
BASE=Path('/mnt/workspace/hermes-persistent/database-snapshots')
HOME=Path('/root/.hermes')
def digest(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
    return h.hexdigest()
def atomic(p,data):
    tmp=p.with_name(p.name+'.new-'+str(os.getpid()));tmp.write_text(json.dumps(data,indent=2));os.replace(tmp,p)
def sources():
    homes=[HOME,*[p for p in (HOME/'profiles').iterdir() if p.is_dir()]]
    directories=[directory for home in homes for directory in [home,home/'cron',home/'webui'] if directory.is_dir()]
    return sorted(p for directory in directories for p in directory.glob('*.db') if p.is_file() and p.open('rb').read(16)==b'SQLite format 3\0')
def signature():
    result={}
    for p in sources():
        for f in [p,Path(str(p)+'-wal')]:
            if f.exists():s=f.stat();result[str(f.relative_to(HOME))]=[s.st_size,s.st_mtime_ns]
    return result
def latest(verify_files=False):
    pointer=BASE/'latest.json'
    def validated(manifest):
        d=json.loads(manifest.read_text())
        if not d.get('files') or d.get('generation')!=manifest.parent.name:raise RuntimeError('Invalid checkpoint generation')
        if verify_files:
            for item in d['files']:
                rel=Path(item['file'])
                if rel.is_absolute() or '..' in rel.parts:raise RuntimeError('Unsafe checkpoint object path')
                if digest(BASE/rel)!=item['gzip_sha256']:raise RuntimeError('Checkpoint object hash mismatch')
        return d
    if pointer.exists():
        try:
            d=json.loads(pointer.read_text());rel=Path(d['manifest'])
            if rel.is_absolute() or '..' in rel.parts:raise RuntimeError('Unsafe checkpoint manifest path')
            manifest=BASE/rel
            if digest(manifest)!=d['sha256']:raise RuntimeError('Checkpoint manifest hash mismatch')
            return validated(manifest)
        except (OSError,ValueError,KeyError,RuntimeError):pass
    # OSSFS cannot guarantee a POSIX-atomic pointer update. Completed immutable
    # generations remain recoverable when the pointer or newest object is damaged.
    for manifest in sorted(BASE.glob('generation-*/manifest.json'),reverse=True):
        try:
            result=validated(manifest);print('CHECKPOINT_FALLBACK',result['generation'],flush=True);return result
        except (OSError,ValueError,KeyError,RuntimeError):continue
    if pointer.exists():raise RuntimeError('No valid database checkpoint remains')
    return None
def save(force=False):
    BASE.mkdir(parents=True,exist_ok=True,mode=0o700)
    with open('/run/hermes-sqlite-checkpoint.lock','w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        sig=signature();old=latest()
        if old and old.get('source_signature')==sig and not force:return old
        if shutil.disk_usage('/tmp').free<1024**3:raise RuntimeError('Less than 1 GiB local free space; preserving existing checkpoint')
        gen=BASE/('generation-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'));gen.mkdir(mode=0o700)
        records=[]
        for src in sources():
            rel=str(src.relative_to(HOME));name=rel.replace('/','__')+'.gz';dst=gen/name
            inp=sqlite3.connect(src.as_uri()+'?mode=ro',uri=True,timeout=20);mem=sqlite3.connect(':memory:')
            try:
                inp.backup(mem,pages=4096,sleep=0.01)
                if mem.execute('PRAGMA quick_check').fetchone()[0]!='ok':raise RuntimeError('Source snapshot integrity check failed: '+rel)
                raw=mem.serialize()
            finally:inp.close();mem.close()
            rawsha=hashlib.sha256(raw).hexdigest()
            with gzip.open(dst,'wb',compresslevel=3) as f:
                view=memoryview(raw)
                for offset in range(0,len(raw),4*1024*1024):f.write(view[offset:offset+4*1024*1024])
            n=len(raw);del view,raw
            verify=hashlib.sha256()
            with gzip.open(dst,'rb') as f:
                for chunk in iter(lambda:f.read(1024*1024),b''):verify.update(chunk)
            if verify.hexdigest()!=rawsha:raise RuntimeError('Compressed checkpoint did not round-trip: '+rel)
            records.append({'source_relative':rel,'file':str(dst.relative_to(BASE)),'raw_bytes':n,'database_sha256':rawsha,'gzip_bytes':dst.stat().st_size,'gzip_sha256':digest(dst),'quick_check':'ok'})
            print('CHECKPOINT_DB',rel,n,flush=True)
        result={'generation':gen.name,'created_at':datetime.now(timezone.utc).isoformat(),'source_signature':sig,'files':records}
        mf=gen/'manifest.json';atomic(mf,result);check=json.loads(mf.read_text());assert check==result
        atomic(BASE/'latest.json',{'manifest':str(mf.relative_to(BASE)),'sha256':digest(mf)})
        # Keep the latest checkpoint and one verified rollback generation.
        completed=[]
        for candidate in BASE.glob('generation-*'):
            if candidate.is_symlink() or not (candidate/'manifest.json').is_file():continue
            record=json.loads((candidate/'manifest.json').read_text())
            if record.get('generation')==candidate.name and 'source_signature' in record and all(x.get('quick_check')=='ok' for x in record.get('files',[])):completed.append(candidate)
        for obsolete in sorted(completed,reverse=True)[2:]:
            if obsolete.resolve().parent!=BASE.resolve():raise RuntimeError('Unsafe checkpoint cleanup path')
            shutil.rmtree(obsolete)
        print('CHECKPOINT_COMMITTED',gen.name,len(records),flush=True);return result
def restore(test_root=None):
    data=latest(verify_files=True)
    if data is None:raise RuntimeError('No consistent database checkpoint; refusing an empty database boot')
    target=Path(test_root) if test_root else HOME
    if test_root:
        if not target.is_absolute() or not str(target).startswith('/tmp/hermes-checkpoint-restore-test-'):raise RuntimeError('Unsafe restore test target')
    else:
        if os.environ.get('HERMES_BOOT_RESTORE')!='1':raise RuntimeError('Live restore requires explicit startup context')
        for proc in Path('/proc').iterdir():
            if not proc.name.isdigit():continue
            try:args=(proc/'cmdline').read_bytes().split(b'\0')
            except (FileNotFoundError,PermissionError,ProcessLookupError):continue
            if b'gateway' in args and (b'hermes_cli.main' in args or any(a.endswith(b'/hermes') for a in args)):raise RuntimeError('Stop Hermes gateway before restoring databases')
        if Path('/run/hermes-database-restore-complete').exists():return
    rollback=Path(tempfile.mkdtemp(prefix='hermes-db-boot-rollback-',dir='/tmp'))
    restored=[]
    for item in data['files']:
        rel=Path(item['source_relative'])
        if rel.is_absolute() or '..' in rel.parts:raise RuntimeError('Unsafe checkpoint database target')
        src=BASE/item['file'];assert digest(src)==item['gzip_sha256']
        dst=target/rel;dst.parent.mkdir(parents=True,exist_ok=True,mode=0o700);temp=dst.with_name(dst.name+'.restore-'+str(os.getpid()))
        h=hashlib.sha256();n=0
        with gzip.open(src,'rb') as inp,open(temp,'wb') as out:
            for chunk in iter(lambda:inp.read(1024*1024),b''):out.write(chunk);h.update(chunk);n+=len(chunk)
            out.flush();os.fsync(out.fileno())
        assert h.hexdigest()==item['database_sha256'] and n==item['raw_bytes']
        db=sqlite3.connect(temp.as_uri()+'?mode=ro',uri=True)
        try:assert db.execute('PRAGMA quick_check').fetchone()[0]=='ok'
        finally:db.close()
        for existing in [dst,Path(str(dst)+'-wal'),Path(str(dst)+'-shm')]:
            if existing.exists():
                old=rollback/str(existing.relative_to(target));old.parent.mkdir(parents=True,exist_ok=True,mode=0o700);os.rename(existing,old)
        os.replace(temp,dst);restored.append(str(rel));print('RESTORED_DB',str(rel),flush=True)
    result={'generation':data['generation'],'database_count':len(restored),'passed':True,'restored_at':datetime.now(timezone.utc).isoformat()}
    if not test_root:atomic(Path('/run/hermes-database-restore-complete'),result)
    if not any(rollback.iterdir()):rollback.rmdir()
    print('RESTORE_VERIFIED',json.dumps(result),flush=True);return result
def daemon():
    with open('/run/hermes-sqlite-checkpoint-daemon.lock','w') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return
        while True:
            try:save()
            except Exception as e:print('CHECKPOINT_ERROR',type(e).__name__,str(e)[:200],flush=True)
            time.sleep(900)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['save','restore','daemon']);p.add_argument('--force',action='store_true');p.add_argument('--test-root');a=p.parse_args()
    if a.action=='save':save(a.force)
    elif a.action=='restore':restore(a.test_root)
    else:daemon()
