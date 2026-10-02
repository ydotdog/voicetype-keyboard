"""Publish only VoiceType company pages to the established company web root.

The remote operation snapshots the company site and Caddy configuration, checks
all existing non-VoiceType file hashes, validates Caddy before reload, and verifies
the public page bytes. No backend or container replacement is performed.
"""
from pathlib import Path
import base64
import io
import json
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/company-pages-20261002"
OUTPUT.mkdir(parents=True, exist_ok=True)
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15",
       "-o", "HostKeyAlias=compute.1837820971458547537", "-o", "UserKnownHostsFile=/Users/kyleqi/.ssh/google_compute_known_hosts",
       "-i", "/Users/kyleqi/.ssh/google_compute_engine", "kq_apeonwheels_com@34.10.43.168"]
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w:gz") as tar:
    for item in sorted((ROOT / "website/voicetype").rglob("*")):
        if item.is_file():
            tar.add(item, arcname=str(item.relative_to(ROOT / "website/voicetype")))
payload = base64.b64encode(archive.getvalue()).decode()
remote = r'''
import base64,hashlib,io,json,os,pathlib,shutil,subprocess,tarfile,time,urllib.request
root=pathlib.Path('/opt/migration-20260917/apps/source/root/apeonwheels_source')
config=pathlib.Path('/opt/voicetype/config/Caddyfile')
container='gcp-vm-caddy-1'
stamp=time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
backup=pathlib.Path('/opt/voicetype/backups')/('company-voicetype-'+stamp)
backup.mkdir(mode=0o700,parents=True,exist_ok=False)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def other_manifest():return {str(p.relative_to(root)):digest(p) for p in root.rglob('*') if p.is_file() and p.relative_to(root).parts[0]!='voicetype'}
before=other_manifest()
(backup/'other-pages-manifest.json').write_text(json.dumps(before,sort_keys=True,indent=2))
with tarfile.open(backup/'company-site-before.tar.gz','w:gz') as tar:tar.add(root,arcname='apeonwheels_source')
previous=config.read_text()
(backup/'Caddyfile.before').write_text(previous)
assert 'voicetype.y.dog {' in previous
assert 'apeonwheels.com www.apeonwheels.com {' in previous
candidate=previous
marker='# VoiceType company information pages'
routes=''' + repr('''
	# VoiceType company information pages
	@voicetype_privacy path /privacy /privacy/ /privacy-policy /privacy-policy/
	redir @voicetype_privacy https://apeonwheels.com/voicetype/privacy/ 308
	@voicetype_support path /support /support/ /help /help/
	redir @voicetype_support https://apeonwheels.com/voicetype/support/ 308
''') + r'''
if marker not in previous:candidate=previous.replace('voicetype.y.dog {','voicetype.y.dog {'+routes,1)
candidate_file=backup/'Caddyfile.candidate'
candidate_file.write_text(candidate)
subprocess.run(['docker','cp',str(candidate_file),container+':/tmp/voicetype-company.Caddyfile'],check=True,capture_output=True)
validation=subprocess.run(['docker','exec',container,'caddy','validate','--config','/tmp/voicetype-company.Caddyfile','--adapter','caddyfile'],check=True,capture_output=True,text=True)
target=root/'voicetype'
staging=root/('.voicetype-'+stamp)
staging.mkdir(mode=0o755)
with tarfile.open(fileobj=io.BytesIO(base64.b64decode(PAYLOAD)),mode='r:gz') as tar:
 for member in tar.getmembers():
  relative=pathlib.PurePosixPath(member.name)
  assert member.isfile() and not relative.is_absolute() and '..' not in relative.parts
  path=staging/member.name
  path.parent.mkdir(parents=True,exist_ok=True)
  path.write_bytes(tar.extractfile(member).read())
  path.chmod(0o644)
if target.exists():shutil.move(str(target),str(backup/'voicetype-before'))
staging.rename(target)
try:
 config.write_text(candidate)
 subprocess.run(['docker','exec',container,'caddy','reload','--config','/etc/caddy/Caddyfile','--adapter','caddyfile'],check=True,capture_output=True,text=True)
 time.sleep(1)
 pages=[]
 for path in sorted(target.rglob('*')):
  if not path.is_file():continue
  suffix=str(path.relative_to(target))
  url='https://apeonwheels.com/voicetype/'+suffix.replace('index.html','')
  with urllib.request.urlopen(url,timeout=25) as response:
   content=response.read()
   assert response.status==200 and hashlib.sha256(content).hexdigest()==digest(path),(url,response.status)
   pages.append({'url':url,'status':response.status,'sha256':digest(path),'bytes':len(content)})
 redirects=[]
 for path,destination in [('privacy','privacy/'),('privacy-policy','privacy/'),('support','support/'),('help','support/')]:
  url='https://voicetype.y.dog/'+path
  with urllib.request.urlopen(url,timeout=25) as response:
   expected='https://apeonwheels.com/voicetype/'+destination
   assert response.status==200 and response.url==expected
   redirects.append({'from':url,'to':response.url,'final_status':response.status})
 assert other_manifest()==before,'An unrelated company file changed'
 for url in ['https://apeonwheels.com/','https://apeonwheels.com/guanxiang/privacy/','https://apeonwheels.com/moneyflow/privacy/','https://voicetype.y.dog/health']:
  with urllib.request.urlopen(url,timeout=25) as response:assert response.status==200,(url,response.status)
except Exception:
 config.write_text(previous)
 subprocess.run(['docker','exec',container,'caddy','reload','--config','/etc/caddy/Caddyfile','--adapter','caddyfile'],check=True,capture_output=True)
 raise
result={'backup':str(backup),'pages':pages,'redirects':redirects,'unrelated_files_unchanged':len(before),'containers_restarted':False,'validated_at_utc':stamp}
(backup/'verification.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
'''
remote = "PAYLOAD=" + repr(payload) + "\n" + remote
result = subprocess.run(SSH + ["sudo -n python3 -"], input=remote, text=True,
                        capture_output=True, timeout=180)
if result.returncode:
    print(result.stdout[-2000:])
    print(result.stderr[-2000:])
    raise SystemExit(result.returncode)
parsed = json.loads(result.stdout)
(OUTPUT / "production-verification.json").write_text(json.dumps(parsed, indent=2))
print(json.dumps(parsed, indent=2))
