#!/usr/bin/env python3
"""Apply only reviewed Docker log rotation settings; run on the VM with --execute.

Preserves all running image IDs, environment files and data mounts. Recreates the
three Compose services. Run only after the backup-restoration check has passed.
No raw environment, logs or database rows are printed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

COMPOSE = Path('/opt/voicetype/app/deploy/gcp-vm/docker-compose.yml')
CANDIDATE = Path('/tmp/voicetype-compose20-logbounds.yml')
BACKUP = Path('/opt/voicetype/backups/build20-20260913T222748Z-bf4a08a2b883/docker-compose.before-log-bounds.yml')
OLD_SHA = 'bc186200e70468ffc0700bca4835a40cb33d76ad4eba9a22e0b2ad370ea0f73e'
NEW_SHA = 'ad096863d3ab3b319a630f9da6a634b6e16044b85d776e93942a52c0c5b64347'
BLOCK = b'    logging:\n      driver: json-file\n      options:\n        max-size: "10m"\n        max-file: "3"\n'
NAMES = ['gcp-vm-postgres-1', 'gcp-vm-backend-1', 'gcp-vm-caddy-1']


def run(args, timeout=120):
    result = subprocess.run(args, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Service maintenance command failed; private output withheld.')
    return result.stdout


def inspect(name):
    return json.loads(run(['docker', 'inspect', name]))[0]


def environment_values(info):
    # Docker/Compose may reorder entries while preserving every key and value.
    return dict(item.split('=', 1) for item in info['Config']['Env'])


def atomic_write(path, data):
    temporary = path.with_name(path.name + '.logbounds20.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary, path.stat().st_mode & 0o777)
    os.replace(temporary, path)


def execute():
    old, new = COMPOSE.read_bytes(), CANDIDATE.read_bytes()
    assert hashlib.sha256(old).hexdigest() == OLD_SHA, 'Live Compose changed.'
    assert hashlib.sha256(new).hexdigest() == NEW_SHA, 'Candidate Compose changed.'
    assert new.count(BLOCK) == 3 and new.replace(BLOCK, b'') == old, 'Expected log-only change.'
    before = {name: inspect(name) for name in NAMES}
    assert before['gcp-vm-backend-1']['Image'] == 'sha256:5cbc491c61c448e570c4f28af38c1700a0021ce808c183fa5197f4cd1c939155'
    for info in before.values():
        assert info['State']['Running'], 'Service is not running.'
        image = json.loads(run(['docker', 'image', 'inspect', info['Config']['Image']]))[0]
        assert image['Id'] == info['Image'], 'Image alias changed; maintenance must not change images.'
        assert info['Config']['Labels']['com.docker.compose.project'] == 'gcp-vm'
    fd = os.open(BACKUP, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as target:
        target.write(old)
        target.flush()
        os.fsync(target.fileno())
    atomic_write(COMPOSE, new)
    base = ['docker', 'compose', '--project-name', 'gcp-vm', '--file', str(COMPOSE)]
    run(base + ['config', '--quiet'])
    run(base + ['up', '-d', '--no-build', '--pull', 'never', '--timeout', '60', '--wait', '--wait-timeout', '120'], timeout=240)
    evidence = []
    for name, previous in before.items():
        current = inspect(name)
        assert current['State']['Running'] and current['Image'] == previous['Image']
        assert environment_values(current) == environment_values(previous), 'Environment changed.'
        assert current['Mounts'] == previous['Mounts'], 'Data/certificate mounts changed.'
        assert current['HostConfig']['PortBindings'] == previous['HostConfig']['PortBindings'], 'Ports changed.'
        assert current['HostConfig']['LogConfig'] == {'Type': 'json-file', 'Config': {'max-size': '10m', 'max-file': '3'}}
        assert current['State'].get('Health', {}).get('Status', 'healthy') == 'healthy'
        evidence.append({'service': name, 'running': True, 'same_image_environment_mounts_ports': True, 'log_max_size': '10m', 'log_max_files': 3})
    for attempt in range(12):
        try:
            with urllib.request.urlopen('https://voicetype.y.dog/health/ready', timeout=10) as response:
                ready = json.load(response)
            assert ready['ok'] is True and len(ready['checks']) == 13 and all(ready['checks'].values())
            break
        except Exception:
            if attempt == 11:
                raise RuntimeError('Public readiness verification failed after log-bound maintenance.') from None
            time.sleep(2)
    print(json.dumps({'log_bounds_applied': evidence, 'public_readiness_checks_passed': 13,
                      'source_and_database_contents_untouched': True}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    if parser.parse_args().execute:
        execute()
    else:
        print('Plan: verify the exact log-only Compose diff and image aliases, back up Compose, apply 10 MiB × 3 files per service, recreate with existing images and unchanged environment/data mounts/ports, verify all 13 readiness checks. Run only after the isolated backup restoration passed.')
