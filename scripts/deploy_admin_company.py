#!/usr/bin/env python3
"""Move the existing owner console to the company URL on the established VM.

Run as root with --release containing a manifest and only the three admin files.
No database migrations or provider changes are introduced. Normal backend startup
retains its existing initialization and expired-reservation cleanup. Credentials are preserved. The old
image, source, environment and Caddy config are retained for automatic rollback.
"""
import argparse, hashlib, json, os, shutil, subprocess, time, urllib.request
from pathlib import Path

BASE = Path('/opt/voicetype')
APP = BASE / 'app'
ENV = BASE / 'env/backend.env'
CADDY = BASE / 'config/Caddyfile'
FILES = ['provider_admin.py', 'admin/index.html', 'admin/admin.js']
COMPOSE = ['docker','compose','--project-name','gcp-vm','--file',str(APP/'deploy/gcp-vm/docker-compose.yml')]

def run(args, *, data=None):
    p = subprocess.run(args, input=data, capture_output=True, timeout=210)
    if p.returncode: raise RuntimeError('Deployment command failed; raw output withheld: '+args[0])
    return p.stdout

def inspect(name): return json.loads(run(['docker','inspect',name]))[0]
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def write_private(path, data):
    path.write_bytes(data); path.chmod(0o600)
def readiness():
    for _ in range(40):
        try:
            value = json.loads(run(['docker','exec','gcp-vm-backend-1','python','-c',"import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/health/ready',timeout=3).read().decode())"]))
            if value['ok']: return value
        except Exception: pass
        time.sleep(1)
    raise RuntimeError('Backend readiness failed')

def deploy(release):
    assert os.getuid()==0 and release.is_absolute()
    manifest=json.loads((release/'manifest.json').read_text())
    assert set(manifest['files'])==set(FILES)
    for file, expected in manifest['files'].items(): assert digest(release/file)==expected
    before={name:inspect(name) for name in run(['docker','ps','--format','{{.Names}}']).decode().split()}
    old=before['gcp-vm-backend-1']
    assert old['Image']==manifest['expected_image'], 'Live image changed'
    active=run(['docker','exec','gcp-vm-postgres-1','psql','-U','voicetype','-d','voicetype','-Atc','SELECT count(*) FROM credit_reservations']).decode().strip()
    assert active=='0', 'Wait for active transcription reservations before switching'
    provider=BASE/'data/provider/settings.enc'; provider_digest=digest(provider)
    stamp=time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
    backup=BASE/'backups'/('admin-company-'+stamp); backup.mkdir(mode=0o700)
    for file in FILES:
        target=backup/'backend'/file; target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(APP/'backend'/file,target)
    write_private(backup/'backend.env',ENV.read_bytes()); write_private(backup/'Caddyfile',CADDY.read_bytes())
    write_private(backup/'old-image.txt',old['Image'].encode())
    source=CADDY.read_text()
    assert '# VoiceType company owner console' not in source, 'Console migration already applied'
    source=source.replace('voicetype.y.dog {','''voicetype.y.dog {
    # VoiceType company owner console
    @old_admin path /admin /admin/*
    redir @old_admin https://apeonwheels.com/voicetype{uri} 308
    @company_admin path /voicetype/admin /voicetype/admin/*
    redir @company_admin https://apeonwheels.com{uri} 308''',1)
    old_company='''apeonwheels.com www.apeonwheels.com {
    encode zstd gzip
    reverse_proxy migration-static:80
}'''
    new_company='''apeonwheels.com www.apeonwheels.com {
    encode zstd gzip
    @www_admin {
        host www.apeonwheels.com
        path /voicetype/admin /voicetype/admin/*
    }
    redir @www_admin https://apeonwheels.com{uri} 308
    @voicetype_admin path /voicetype/admin /voicetype/admin/*
    handle @voicetype_admin {
        reverse_proxy backend:8080 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
        }
    }
    handle {
        reverse_proxy migration-static:80
    }
}'''
    assert old_company in source, 'Company virtual host changed'
    source=source.replace(old_company,new_company,1)
    candidate_config=release/'Caddyfile.candidate'; candidate_config.write_text(source)
    run(['docker','cp',str(candidate_config),'gcp-vm-caddy-1:/tmp/admin-company.Caddyfile'])
    run(['docker','exec','gcp-vm-caddy-1','caddy','validate','--config','/tmp/admin-company.Caddyfile','--adapter','caddyfile'])
    base_tag='gcp-vm-backend:before-admin-company-'+stamp
    run(['docker','tag',old['Image'],base_tag])
    (release/'Dockerfile').write_text('FROM '+base_tag+'\nCOPY provider_admin.py /app/provider_admin.py\nCOPY admin/index.html admin/admin.js /app/admin/\n')
    tag='gcp-vm-backend:admin-company-'+stamp
    run(['docker','build','-t',tag,str(release)])
    new_image=json.loads(run(['docker','image','inspect',tag]))[0]['Id']
    current_env=ENV.read_text().splitlines()
    changes={'ADMIN_ORIGIN':'https://apeonwheels.com','ADMIN_BASE_PATH':'/voicetype/admin'}
    new_env=[line for line in current_env if line.split('=',1)[0] not in changes]
    new_env.extend(k+'='+v for k,v in changes.items())
    active=run(['docker','exec','gcp-vm-postgres-1','psql','-U','voicetype','-d','voicetype','-Atc','SELECT count(*) FROM credit_reservations']).decode().strip()
    assert active=='0', 'New transcription started; retry the switch after it finishes'
    try:
        for file in FILES: shutil.copy2(release/file,APP/'backend'/file)
        write_private(ENV,('\n'.join(new_env)+'\n').encode())
        run(['docker','tag',new_image,'gcp-vm-backend:latest'])
        run(COMPOSE+['up','-d','--no-deps','--no-build','--timeout','150','backend'])
        ready=readiness(); assert inspect('gcp-vm-backend-1')['Image']==new_image
        CADDY.write_text(source)
        run(['docker','exec','gcp-vm-caddy-1','caddy','reload','--config','/etc/caddy/Caddyfile','--adapter','caddyfile'])
        with urllib.request.urlopen('https://apeonwheels.com/voicetype/admin',timeout=15) as response:
            page=response.read().decode(); assert response.status==200 and 'data-admin-base-path="/voicetype/admin"' in page
        with urllib.request.urlopen('https://voicetype.y.dog/admin',timeout=15) as response:
            assert response.url=='https://apeonwheels.com/voicetype/admin'
        for url in ['https://voicetype.y.dog/health/ready','https://apeonwheels.com/','https://apeonwheels.com/voicetype/privacy/','https://apeonwheels.com/voicetype/support/','https://apeonwheels.com/moneyflow/privacy/','https://apeonwheels.com/guanxiang/privacy/']:
            with urllib.request.urlopen(url,timeout=15) as response: assert response.status==200
        assert digest(provider)==provider_digest, 'Provider settings changed'
        for name, state in before.items():
            if name!='gcp-vm-backend-1':
                now=inspect(name); assert now['State']['StartedAt']==state['State']['StartedAt'] and now['State']['Running']
    except Exception:
        rollback_errors=[]
        try:
            for file in FILES: shutil.copy2(backup/'backend'/file,APP/'backend'/file)
            shutil.copy2(backup/'backend.env',ENV)
            run(['docker','tag',old['Image'],'gcp-vm-backend:latest'])
            run(COMPOSE+['up','-d','--no-deps','--no-build','--timeout','150','backend'])
            readiness()
        except Exception:
            rollback_errors.append('backend')
        try:
            shutil.copy2(backup/'Caddyfile',CADDY)
            run(['docker','exec','gcp-vm-caddy-1','caddy','reload','--config','/etc/caddy/Caddyfile','--adapter','caddyfile'])
        except Exception:
            rollback_errors.append('Caddy')
        if rollback_errors:
            raise RuntimeError('Deployment failed; manual recovery needed for '+', '.join(rollback_errors)+'; backup: '+str(backup)) from None
        raise
    result={'url':'https://apeonwheels.com/voicetype/admin','image':new_image,'backup':str(backup),'readiness':ready,'provider_configuration_unchanged':True,'other_containers_unchanged':True}
    (release/'success.json').write_text(json.dumps(result,indent=2)); print(json.dumps(result,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--release',required=True,type=Path)
    deploy(parser.parse_args().release)
