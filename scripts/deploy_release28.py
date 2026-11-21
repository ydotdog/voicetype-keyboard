#!/usr/bin/env python3
"""Deploy a checksummed release after isolated QA and a verified restore.

Run on the existing VoiceType VM as root with --release /absolute/release/path.
Only the backend container is recreated; credentials and backups stay private.
No live database is ever restored by this worker. Existing admin keys are retained.
"""
from __future__ import annotations
import argparse, base64, hashlib, importlib.util, json, os, secrets, shutil, subprocess, time
from pathlib import Path

BASE = Path('/opt/voicetype')
APP = BASE / 'app'
COMPOSE = APP / 'deploy/gcp-vm/docker-compose.yml'
ENV = BASE / 'env/backend.env'
TAG = 'gcp-vm-backend:release28'

def run(args, *, data=None, timeout=900, log=None):
    result = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
    if log:
        log.write_bytes(result.stdout + result.stderr); log.chmod(0o600)
    if result.returncode:
        raise RuntimeError('Command failed: ' + args[0] + '; output retained privately' if log else 'Command failed; private output withheld.')
    return result.stdout

def inspect(name): return json.loads(run(['docker','inspect',name]))[0]
def private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
def module(path, name):
    spec=importlib.util.spec_from_file_location(name,path); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

def execute(release):
    manifest=json.loads((release/'release-manifest.json').read_text())
    for name, expected in manifest.items():
        assert hashlib.sha256((release/name).read_bytes()).hexdigest()==expected, 'Payload changed'
    assert inspect('gcp-vm-backend-1')['Image']=='sha256:be5c4e290a559b0adc2af0aede2bfbf8548f656353d0831cc52b2ff680fbf8f6', 'Production baseline changed'
    assert shutil.disk_usage(BASE).free > 4_000_000_000, 'Insufficient backup space'
    ids=run(['docker','ps','-q']).decode().split()
    before={i:inspect(i) for i in ids}
    old=inspect('gcp-vm-backend-1'); pg=inspect('gcp-vm-postgres-1')
    run(['docker','build','-t',TAG,str(release/'backend')],log=release/'build.private.log')
    image=json.loads(run(['docker','image','inspect',TAG]))[0]
    assert image['Config']['User']=='appuser'
    image_id=image['Id']
    print('Candidate image built:',image_id,flush=True)
    qa_dockerfile=release/'Dockerfile.qa'
    qa_dockerfile.write_text('FROM '+TAG+'\nUSER root\nRUN pip install --no-cache-dir pytest==8.4.2\nUSER appuser\n')
    run(['docker','build','-f',str(qa_dockerfile),'-t','voicetype-qa:release28',str(release)],log=release/'qa-build.private.log')
    run(['docker','run','--rm','--network','none','--cap-drop','ALL','--security-opt','no-new-privileges',
         '-v',str(release)+':/qa:ro','-w','/qa','voicetype-qa:release28','python','-m','pytest','-q','-p','no:cacheprovider','backend/tests','tests'],log=release/'pytest.private.log')
    print('Container backend and shared regression tests passed.',flush=True)
    # Fresh isolated Postgres; no production credentials or volumes supplied.
    qa_name='voicetype-release-qa28-'+secrets.token_hex(5)
    qa_id=run(['docker','run','-d','--rm','--name',qa_name,'--network','none','--memory','512m','--tmpfs','/var/lib/postgresql/data:rw,size=256m',
        '-e','POSTGRES_HOST_AUTH_METHOD=trust','-e','POSTGRES_USER=qa','-e','POSTGRES_DB=voicetype_release_qa_28',pg['Image']]).decode().strip()
    try:
        for _ in range(60):
            result=subprocess.run(['docker','exec',qa_id,'pg_isready','-U','qa'],capture_output=True)
            if result.returncode==0: break
            time.sleep(.5)
        else: raise RuntimeError('QA Postgres did not start')
        run(['docker','run','--rm','--network','container:'+qa_id,'--cap-drop','ALL',
            '-e','DATABASE_URL=postgresql://qa@127.0.0.1:5432/voicetype_release_qa_28',
            '-v',str(release/'scripts')+':/qa:ro',image_id,'python','/qa/verify_postgres_release.py','--database-name','voicetype_release_qa_28'],log=release/'postgres.private.log')
        run(['docker','run','--rm','--network','container:'+qa_id,'--cap-drop','ALL',
            '-e','DATABASE_URL=postgresql://qa@127.0.0.1:5432/voicetype_release_qa_28',
            '-v',str(release)+':/qa:ro',image_id,'python','/qa/scripts/verify_backend_media_release.py',
            '--database-name','voicetype_release_qa_28','--audio-path','/qa/qa-media.m4a',
            '--expected-audio-sha256',hashlib.sha256((release/'qa-media.m4a').read_bytes()).hexdigest(),
            '--expected-backend-sha256',manifest['backend/main.py']],log=release/'media.private.log')
        print('Isolated Postgres transactions and real-media checks passed.',flush=True)
    finally:
        assert inspect(qa_id)['Name']=='/'+qa_name
        run(['docker','rm','-f',qa_id])
    stamp=time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
    backup=BASE/'backups'/('release28-'+stamp); backup.mkdir(mode=0o700)
    private(backup/'runtime-inspect.private.json',json.dumps(before).encode())
    for name,path in [('backend.env',ENV),('db.env',BASE/'env/db.env')]: private(backup/name,path.read_bytes())
    run(['tar','-czf',str(backup/'source.tar.gz'),'-C',str(APP),'backend','deploy/gcp-vm'])
    run(['docker','image','save','-o',str(backup/'backend-image.tar'),old['Image']])
    private(backup/'database.dump',run(['docker','exec',pg['Id'],'pg_dump','-U','voicetype','-d','voicetype','-Fc','--no-owner','--no-acl']))
    for path in backup.iterdir(): path.chmod(0o600)
    verifier=module(release/'scripts/verify_backup_restore20.py','restore_verifier')
    verifier.DUMP=backup/'database.dump'; verifier.DUMP_SHA=hashlib.sha256(verifier.DUMP.read_bytes()).hexdigest(); verifier.verify()
    print('Production database backup restored and compared successfully.',flush=True)
    # One-time owner credentials. Retain all existing sensitive configuration.
    settings={line.split('=',1)[0].strip():line.split('=',1)[1].strip() for line in ENV.read_text().splitlines() if '=' in line and not line.startswith('#')}
    additions={}
    for key,value in {'ADMIN_SESSION_SECRET':secrets.token_urlsafe(48),'ADMIN_ORIGIN':'https://voicetype.y.dog',
                      'PROVIDER_CONFIG_PATH':'/data/provider/settings.enc','PROVIDER_CONFIG_ENCRYPTION_KEY':base64.urlsafe_b64encode(secrets.token_bytes(32)).decode()}.items():
        if not settings.get(key): additions[key]=value
    if not settings.get('ADMIN_PASSWORD_HASH'):
        password=secrets.token_urlsafe(24); salt=secrets.token_hex(16)
        digest=base64.b64encode(hashlib.pbkdf2_hmac('sha256',password.encode(),salt.encode(),600000)).decode()
        additions['ADMIN_PASSWORD_HASH']='pbkdf2_sha256$'+salt+'$'+digest
        private(BASE/'env/admin-access.txt',('VoiceType owner console\nhttps://voicetype.y.dog/admin\nPassword: '+password+'\nKeep private. API keys are entered only in this console.\n').encode())
    contents=ENV.read_text().rstrip()+'\n'+''.join(k+"='"+v+"'\n" for k,v in additions.items())
    temp=ENV.with_name('backend.env.release28'); private(temp,contents.encode()); os.replace(temp,ENV)
    provider=BASE/'data/provider'; provider.mkdir(mode=0o700,exist_ok=True); os.chown(provider,10001,10001)
    # Install the reviewed files without deleting unrelated service sources.
    for relative in manifest:
        source=release/relative; target=APP/relative; target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,target)
    for i,info in before.items():
        now=inspect(i); assert now['State']['StartedAt']==info['State']['StartedAt'] and now['State']['Running'], 'A live service changed before switch'
    run(['docker','tag',image_id,'gcp-vm-backend:latest'])
    run(['docker','compose','--project-name','gcp-vm','--file',str(COMPOSE),'up','-d','--no-deps','--no-build','backend'],log=release/'switch.private.log')
    current=inspect('gcp-vm-backend-1'); assert current['Image']==image_id
    ready=None
    for _ in range(40):
        try:
            data=run(['docker','exec',current['Id'],'python','-c',"import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/health/ready',timeout=4).read().decode())"])
            ready=json.loads(data); assert ready['ok']; break
        except Exception: time.sleep(1)
    assert ready and ready['ok'], 'Candidate readiness failed; inspect private release logs'
    for i,info in before.items():
        if info['Id']==old['Id']: continue
        now=inspect(i); assert now['State']['StartedAt']==info['State']['StartedAt'] and now['State']['Running'], 'An unrelated service changed'
    import urllib.request
    public=json.load(urllib.request.urlopen('https://voicetype.y.dog/health/ready',timeout=15)); assert public['ok']
    evidence={'image':image_id,'backup':str(backup),'readiness':public,'isolated_pg_passed':True,'backup_restored_and_compared':True,'other_services_unchanged':True}
    (release/'success.json').write_text(json.dumps(evidence,indent=2))
    print(json.dumps(evidence,indent=2),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--release',required=True,type=Path); args=parser.parse_args()
    assert os.getuid()==0 and args.release.is_absolute()
    execute(args.release)
