#!/usr/bin/env python3
"""Restore the pinned release backup into an ephemeral, network-isolated PG16.

Run on the VoiceType VM with --execute. The default only prints the plan.
No live database connection, application process or provider request is used.
The temporary database is held in bounded tmpfs and removed after verification.
Raw dump contents, credentials and customer rows are never logged.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import secrets
import subprocess
import time


DUMP = Path('/opt/voicetype/backups/build20-20260913T222748Z-bf4a08a2b883/database.dump')
DUMP_SHA = '62f55569c3ba27da2f2142b486d5a99104883bb6395c1a54d1ec6f4b99a4dc7e'
LABEL = 'com.voicetype.release-qa=backup-restore20'


def run(args: list[str], *, timeout: int = 90) -> bytes:
    result = subprocess.run(args, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Verification command failed; private output withheld.')
    return result.stdout


def inspect(name: str) -> dict:
    return json.loads(run(['docker', 'inspect', name]))[0]


def data_fingerprint(sql: bytes) -> dict:
    """Compare COPY row multisets and sequence state without displaying data."""
    tables: dict[bytes, list[bytes]] = {}
    sequences: list[bytes] = []
    active = None
    for line in sql.splitlines():
        if active is not None:
            if line == b'\\.':
                active = None
            else:
                tables[active].append(hashlib.sha256(line).digest())
        elif line.startswith(b'COPY ') and line.endswith(b' FROM stdin;'):
            if line in tables:
                raise RuntimeError('Unexpected duplicate COPY section.')
            active = line
            tables[active] = []
        elif line.startswith(b'SELECT pg_catalog.setval('):
            sequences.append(line)
    if active is not None or not tables:
        raise RuntimeError('Incomplete or empty backup data structure.')
    return {
        'tables': {name: hashlib.sha256(b''.join(sorted(rows))).digest()
                   for name, rows in tables.items()},
        'sequences': sorted(sequences),
    }


def verify() -> None:
    if DUMP.resolve() != DUMP or not DUMP.is_file():
        raise RuntimeError('Pinned backup is missing or redirected.')
    if hashlib.sha256(DUMP.read_bytes()).hexdigest() != DUMP_SHA:
        raise RuntimeError('Pinned backup checksum does not match.')
    names = ['gcp-vm-backend-1', 'gcp-vm-postgres-1', 'gcp-vm-caddy-1']
    before = {name: inspect(name) for name in names}
    postgres = before['gcp-vm-postgres-1']
    if not all(info['State']['Running'] for info in before.values()):
        raise RuntimeError('Expected live services to be running.')
    image = postgres['Image']
    name = 'voicetype-release-restore20-' + secrets.token_hex(6)
    identifier = None
    try:
        identifier = run([
            'docker', 'run', '-d', '--rm', '--pull=never', '--name', name,
            '--label', LABEL, '--network', 'none', '--memory', '384m', '--cpus', '1',
            '--tmpfs', '/var/lib/postgresql/data:rw,size=256m',
            '--mount', f'type=bind,source={DUMP},target=/backup.dump,readonly',
            '-e', 'POSTGRES_HOST_AUTH_METHOD=trust',
            '-e', 'POSTGRES_USER=restorecheck', '-e', 'POSTGRES_DB=restorecheck',
            image,
        ]).decode().strip()
        info = inspect(identifier)
        if info['HostConfig']['NetworkMode'] != 'none' or info['Image'] != image:
            raise RuntimeError('Restore container isolation verification failed.')
        for _ in range(40):
            result = subprocess.run(
                ['docker', 'exec', identifier, 'pg_isready', '-h', '127.0.0.1', '-U', 'restorecheck', '-d', 'restorecheck'],
                capture_output=True, timeout=10,
            )
            if result.returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError('Isolated PostgreSQL did not become ready.')
        pg = ['docker', 'exec', identifier]
        version = run(pg + ['psql', '-U', 'restorecheck', '-d', 'restorecheck', '-Atc', 'SHOW server_version_num']).strip()
        if int(version) // 10000 != 16:
            raise RuntimeError('Expected PostgreSQL 16.')
        run(pg + ['pg_restore', '-U', 'restorecheck', '-d', 'restorecheck',
                  '--exit-on-error', '--no-owner', '--no-acl', '/backup.dump'])
        original = run(pg + ['pg_restore', '--data-only', '--no-owner', '--no-acl', '--file=-', '/backup.dump'])
        restored = run(pg + ['pg_dump', '-U', 'restorecheck', '-d', 'restorecheck',
                             '--data-only', '--no-owner', '--no-acl'])
        original_fp, restored_fp = data_fingerprint(original), data_fingerprint(restored)
        if original_fp != restored_fp:
            raise RuntimeError('Restored data or sequence fingerprint does not match the backup.')
        valid = run(pg + ['psql', '-U', 'restorecheck', '-d', 'restorecheck', '-Atc',
                          "SELECT current_database() = 'restorecheck' AND "
                          "NOT EXISTS (SELECT 1 FROM pg_constraint WHERE NOT convalidated) AND "
                          "NOT EXISTS (SELECT 1 FROM pg_index WHERE NOT indisvalid)"]).strip()
        if valid != b't':
            raise RuntimeError('Restored database constraint/index verification failed.')
        if inspect(identifier)['State'].get('OOMKilled'):
            raise RuntimeError('Restore container was killed for memory use.')
        print(json.dumps({'restore_passed': True, 'postgres_major': 16,
                          'dump_sha256': DUMP_SHA, 'all_table_data_and_sequences_match': True,
                          'constraints_and_indexes_valid': True, 'network': 'none',
                          'private_rows_logged': False}, indent=2))
    finally:
        if identifier is not None:
            info = inspect(identifier)
            if info['Name'] != '/' + name or info['Config']['Labels'].get('com.voicetype.release-qa') != 'backup-restore20':
                raise RuntimeError('Temporary container ownership check failed; cleanup refused.')
            run(['docker', 'rm', '-f', identifier])
            print('Temporary restore container and its tmpfs removed.')
    for name, info in before.items():
        after = inspect(name)
        if after['Id'] != info['Id'] or after['State']['StartedAt'] != info['State']['StartedAt'] or not after['State']['Running']:
            raise RuntimeError('A live service changed during verification.')
    print('Production backend, database and Caddy container identities/start times unchanged.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if args.execute:
        verify()
    else:
        print('Plan: verify the pinned dump checksum, restore in network-none PostgreSQL 16 with bounded tmpfs, compare every table and sequence without logging rows, validate indexes/constraints, remove the temporary container, verify live services did not restart.')
