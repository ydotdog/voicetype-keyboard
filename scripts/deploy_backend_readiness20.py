#!/usr/bin/env python3
"""Reviewed-on-host deployment worker; default is a static, non-mutating plan.

This script has NO SSH/gcloud/upload code. The deploy owner must separately copy
the reviewed script and candidate release to the verified VM, finish QA, then run:

  sudo python3 deploy_backend_readiness20.py --execute \
    --candidate-image-id sha256:5cbc491c61c448e570c4f28af38c1700a0021ce808c183fa5197f4cd1c939155

Only the backend service is recreated. No database restore, Caddy restart,
StoreKit/App Store action, or automatic rollback to weaker old billing rules.
After a failed internal health check, stop ONLY the matching candidate backend.
An internally healthy candidate remains running if a later public/network check
fails. Leave the database, backups and stable signup key for the owner's review.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import time
import urllib.request


BASE = Path("/opt/voicetype")
APP = BASE / "app"
COMPOSE = APP / "deploy/gcp-vm/docker-compose.yml"
CANDIDATE = BASE / "releases/20260913-readiness20-uploadlimit/backend"
BACKEND_ENV = BASE / "env/backend.env"
DB_ENV = BASE / "env/db.env"
IMAGE_TAG = "gcp-vm-backend:readiness20-uploadlimit"
CANDIDATE_IMAGE = "sha256:5cbc491c61c448e570c4f28af38c1700a0021ce808c183fa5197f4cd1c939155"
OLD_IMAGE = "sha256:59790461a19fe28b3eb900a3ca4b9c7ac322f99d4dcb2338d22a95c2bd3a63df"
OLD_SOURCE = "4bc9c68ecdba6e46ede9f2df4bb53543c7e878c1d7cc2ff1933347d3fea6d3d8"
PAYLOAD = {
    "main.py": "eecaf9d9a1999d085ced15ae37cc2e33e70e6023db1f26c0a25f709a7d7c6dca",
    "Dockerfile": "e2157b0576c816692125df105854f90ca34f0891b57d768a33516be2ba1e9da8",
    "requirements.txt": "9b1333dc06a3be44e2a092e6519ab160ecc86a24f774301fd735f51c7912f119",
}
CONTAINERS = {
    "backend": "8821142a0d585ec8a994eca3b822dc234d34e2274cd709dafc36771ce17bfccb",
    "postgres": "aeb8e52c4e35a9f645c4f2adb3db54e26a17d38d32a5884d43a842dcfc08c3a0",
    "caddy": "950556dcda642f6dcd792874bff3e22a283d998a4e277ac59f63ccb643a643bc",
}
REQUIRED_CHECKS = {
    "jwt_secret", "signup_grant_stable_secret", "audio_decoder", "openai_api_key",
    "database", "storekit_strict", "storekit_app_account_token_required",
    "apple_app_id", "apple_root_certificates", "apple_signin_revoke_credentials",
    "dev_credit_disabled", "apple_auth_dev_bypass_disabled", "storekit_real_environments_only",
}
COMPOSE_COMMAND = ["docker", "compose", "--project-name", "gcp-vm", "--file", str(COMPOSE)]


class DeploymentFailure(Exception):
    """Messages are fixed diagnostics, never command output or secret values."""


def check(condition: bool, message: str) -> None:
    if not condition:
        raise DeploymentFailure(message)


def run(command: list[str], label: str, *, stdin=None, stdout=None, timeout=120):
    result = subprocess.run(command, stdin=stdin, stdout=stdout or subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, check=False)
    check(result.returncode == 0, label + " failed; command output withheld.")
    return result.stdout


def inspect_container(service: str):
    return json.loads(run(["docker", "inspect", "gcp-vm-" + service + "-1"], "Container inspection"))[0]


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def safe_path(path: Path, *, directory=False) -> None:
    check(path.is_absolute() and path.resolve() == path, "Expected an absolute path without symlink components.")
    check(path.is_dir() if directory else path.is_file(), "A required deployment path is missing.")


def private_write(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as target:
        target.write(data)
        target.flush()
        os.fsync(target.fileno())


def atomic_install(path: Path, data: bytes, mode: int) -> None:
    old = path.stat()
    temporary = path.with_name(path.name + ".readiness20-" + secrets.token_hex(8))
    try:
        private_write(temporary, data)
        os.chmod(temporary, mode)
        os.chown(temporary, old.st_uid, old.st_gid)
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def signup_secret_line(contents: str):
    matches = []
    for index, line in enumerate(contents.splitlines()):
        match = re.fullmatch(r"\s*(?:export\s+)?SIGNUP_GRANT_HMAC_SECRET\s*=\s*(.*?)\s*", line)
        if match:
            matches.append((index, match.group(1)))
    check(len(matches) <= 1, "Duplicate signup identity key definitions require manual review.")
    return matches[0] if matches else None


def provision_signup_secret(backup: Path) -> None:
    original = BACKEND_ENV.read_bytes()
    contents = original.decode("utf-8")
    found = signup_secret_line(contents)
    # Preserve every existing nonempty value, including quoted dotenv values.
    # Do not rotate or reinterpret an existing identity key during deployment.
    if found is not None and found[1] not in {"", "''", '""'}:
        print("Existing signup identity key preserved; value never displayed.")
    else:
        assignment = "SIGNUP_GRANT_HMAC_SECRET=" + secrets.token_urlsafe(48)
        lines = contents.splitlines()
        if found is None:
            lines.append(assignment)
        else:
            lines[found[0]] = assignment
        atomic_install(BACKEND_ENV, ("\n".join(lines) + "\n").encode(), 0o600)
        print("Missing signup identity key provisioned once; value never displayed.")
    os.chmod(BACKEND_ENV, 0o600)
    private_write(backup / "backend.env.with-stable-signup-key", BACKEND_ENV.read_bytes())


def verify_image(image_id: str) -> None:
    description = json.loads(run(["docker", "image", "inspect", IMAGE_TAG], "Candidate image inspection"))[0]
    check(description["Id"] == image_id == CANDIDATE_IMAGE, "Candidate image changed after QA; stop for revalidation.")
    check(description.get("Os") == "linux" and description.get("Architecture") == "amd64", "Unexpected candidate platform.")
    check(description["Config"].get("User", "").split(":")[0] not in {"", "0", "root"}, "Candidate must run as a non-root user.")
    code = "import hashlib,json,pathlib,shutil;print(json.dumps({'main.py':hashlib.sha256(pathlib.Path('/app/main.py').read_bytes()).hexdigest(),'requirements.txt':hashlib.sha256(pathlib.Path('/app/requirements.txt').read_bytes()).hexdigest(),'ffmpeg':bool(shutil.which('ffmpeg'))}))"
    result = json.loads(run(["docker", "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
                             "--security-opt", "no-new-privileges", "--entrypoint", "python", image_id, "-c", code], "Isolated candidate file verification"))
    check(all(result.get(name) == PAYLOAD[name] for name in ("main.py", "requirements.txt")) and result.get("ffmpeg") is True,
          "Candidate image content does not match the reviewed payload.")


def verify_live(initial: dict) -> None:
    for service, identifier in CONTAINERS.items():
        info = inspect_container(service)
        labels = info["Config"].get("Labels") or {}
        check(info["Id"] == identifier and info["State"]["Running"], "A live service changed or is not running.")
        check(labels.get("com.docker.compose.project") == "gcp-vm" and labels.get("com.docker.compose.service") == service,
              "Unexpected Compose project/service ownership.")
        check(labels.get("com.docker.compose.project.config_files") == str(COMPOSE)
              and labels.get("com.docker.compose.project.working_dir") == str(COMPOSE.parent), "Unexpected Compose configuration paths.")
        check(info["State"].get("Health", {}).get("Status", "healthy") == "healthy", "A live service is unhealthy.")
        if initial:
            check(info["State"]["StartedAt"] == initial[service]["State"]["StartedAt"], "A service restarted during preparation.")
    current = inspect_container("backend")
    check(current["Image"] == OLD_IMAGE and current["Config"]["Image"] in {"gcp-vm-backend", "gcp-vm-backend:latest"}, "Live backend image differs from the reviewed baseline.")
    alias = json.loads(run(["docker", "image", "inspect", "gcp-vm-backend:latest"], "Live image alias inspection"))[0]
    check(alias["Id"] == OLD_IMAGE, "The live default image alias changed before deployment.")
    code = "import hashlib,pathlib;print(hashlib.sha256(pathlib.Path('/app/main.py').read_bytes()).hexdigest())"
    check(run(["docker", "exec", CONTAINERS["backend"], "python", "-c", code], "Live source verification").decode().strip() == OLD_SOURCE,
          "Running backend source differs from the reviewed baseline.")
    check(digest(APP / "backend/main.py") == OLD_SOURCE, "Live source directory differs from the running baseline.")


def verify_readiness(payload: dict) -> bool:
    checks = payload.get("checks", {})
    return payload.get("ok") is True and payload.get("service") == "voicetype-api" \
        and REQUIRED_CHECKS <= checks.keys() and all(checks[name] is True for name in REQUIRED_CHECKS)


def wait_for_health(candidate_id: str) -> dict:
    code = "import json,urllib.request;print(json.dumps({p:json.load(urllib.request.urlopen('http://127.0.0.1:8080'+p,timeout=5)) for p in ['/health','/health/ready']}))"
    for _ in range(30):
        try:
            info = inspect_container("backend")
            check(info["Image"] == candidate_id, "Unexpected backend image after switching.")
            payload = json.loads(run(["docker", "exec", info["Id"], "python", "-c", code], "Backend health probe", timeout=15))
            health = payload["/health"]
            if health.get("ok") is True and health.get("database") == "postgres" and health.get("storekit_verification_mode") == "strict" \
                    and verify_readiness(payload["/health/ready"]) and info["State"].get("Health", {}).get("Status") == "healthy":
                return payload
        except (DeploymentFailure, json.JSONDecodeError, subprocess.TimeoutExpired):
            pass
        time.sleep(2)
    raise DeploymentFailure("Candidate health/readiness did not pass within the bounded wait.")


def execute(candidate_id: str) -> None:
    check(sys.platform == "linux" and os.geteuid() == 0 and not Path("/.dockerenv").exists(), "Execute only as root on the production VM host.")
    check(socket.gethostname().split(".")[0] == "voicetype-api", "Unexpected VM hostname.")
    for path in (BASE, APP, CANDIDATE, APP / "backend"):
        safe_path(path, directory=True)
    for path in (COMPOSE, BACKEND_ENV, DB_ENV, *(CANDIDATE / name for name in PAYLOAD), *(APP / "backend" / name for name in PAYLOAD)):
        safe_path(path)
    for name, expected in PAYLOAD.items():
        check(digest(CANDIDATE / name) == expected, "Candidate source hash mismatch.")
    lock_fd = os.open(BASE / ".readiness20-deploy.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(lock_fd)
        raise DeploymentFailure("Another readiness deployment holds the lock.") from None
    switched = False
    internally_healthy = False
    backup = None
    try:
        verify_live({})
        initial = {service: inspect_container(service) for service in CONTAINERS}
        verify_image(candidate_id)
        sql = "SELECT current_database(), current_user, pg_database_size(current_database()), current_setting('server_version_num');"
        database = run(["docker", "exec", CONTAINERS["postgres"], "psql", "-X", "-A", "-t", "-U", "voicetype", "-d", "voicetype", "-c", sql], "Database identity check").decode().strip().split("|")
        check(len(database) == 4 and database[:2] == ["voicetype", "voicetype"] and int(database[3]) // 10000 == 16, "Unexpected production database identity/version.")
        image = json.loads(run(["docker", "image", "inspect", OLD_IMAGE], "Backup sizing"))[0]
        check(shutil.disk_usage(BASE).free > 2 * int(database[2]) + 2 * image["Size"] + 200_000_000, "Insufficient free disk space for verified backups.")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(6)
        backups = BASE / "backups"
        if backups.exists():
            safe_path(backups, directory=True)
        else:
            backups.mkdir(mode=0o700)
        backup = backups / ("build20-" + stamp)
        backup.mkdir(mode=0o700)
        os.umask(0o077)
        print("Backup directory: " + str(backup))
        for name, source in (("backend.env.before", BACKEND_ENV), ("db.env", DB_ENV)):
            private_write(backup / name, source.read_bytes())
        private_write(backup / "runtime-inspect.private.json", json.dumps(initial, sort_keys=True).encode())
        run(["tar", "-czf", str(backup / "source-and-compose.tar.gz"), "-C", str(APP), "backend", "deploy/gcp-vm"], "Source backup", timeout=300)
        rollback_tag = "gcp-vm-backend:before-readiness20-" + stamp.lower()
        run(["docker", "tag", OLD_IMAGE, rollback_tag], "Preserve previous image tag")
        run(["docker", "image", "save", "-o", str(backup / "backend-image.tar"), rollback_tag], "Image backup", timeout=600)
        dump = backup / "database.dump"
        with dump.open("xb") as target:
            run(["docker", "exec", CONTAINERS["postgres"], "pg_dump", "-U", "voicetype", "-d", "voicetype", "--format=custom", "--no-owner", "--no-acl"], "Database snapshot", stdout=target, timeout=600)
            target.flush()
            os.fsync(target.fileno())
        check(dump.stat().st_size > 0, "Database dump is empty.")
        with dump.open("rb") as source:
            toc = run(["docker", "exec", "-i", CONTAINERS["postgres"], "pg_restore", "--list"], "Dump catalog verification", stdin=source)
        check(all(("TABLE DATA public " + table + " ").encode() in toc for table in ("users", "credit_ledger", "storekit_transactions", "transcriptions")), "Dump is missing essential production tables.")
        private_write(backup / "database.dump.toc", toc)
        with dump.open("rb") as source:
            run(["docker", "exec", "-i", CONTAINERS["postgres"], "pg_restore", "--no-owner", "--no-acl", "--file=/dev/null"], "Full dump decompression verification", stdin=source, timeout=600)
        run(["tar", "-tf", str(backup / "backend-image.tar")], "Image archive verification", timeout=300)
        run(["tar", "-tzf", str(backup / "source-and-compose.tar.gz")], "Source archive verification", timeout=300)
        for path in backup.iterdir():
            os.chmod(path, 0o600)
        manifest = {"old_image": OLD_IMAGE, "candidate_image": candidate_id, "candidate_tag": IMAGE_TAG, "rollback_tag": rollback_tag,
                    "payload_sha256": PAYLOAD, "backup_sha256": {p.name: digest(p) for p in backup.iterdir()}, "database_restore_executed": False}
        private_write(backup / "manifest.json", json.dumps(manifest, indent=2, sort_keys=True).encode())
        print("Current image, source, environment and database backups verified.")
        verify_live(initial)
        provision_signup_secret(backup)
        os.chmod(DB_ENV, 0o600)
        # Never shell-source dotenv files or print the resolved Compose config.
        config = json.loads(run(COMPOSE_COMMAND + ["config", "--format", "json"], "Compose environment validation"))
        environment = config["services"]["backend"].get("environment", {})
        check(bool(environment.get("SIGNUP_GRANT_HMAC_SECRET")) and environment.get("SIGNUP_GRANT_HMAC_SECRET") != environment.get("JWT_SECRET"), "A dedicated nonempty signup identity key is required.")
        for name, expected in PAYLOAD.items():
            check(digest(CANDIDATE / name) == expected, "Candidate source changed during backup.")
            destination = APP / "backend" / name
            atomic_install(destination, (CANDIDATE / name).read_bytes(), stat.S_IMODE(destination.stat().st_mode))
        # Default/latest is changed only HERE, after explicit --execute and all
        # baseline/image/payload/database backup checks. No candidate rebuild.
        run(["docker", "tag", candidate_id, initial["backend"]["Config"]["Image"]], "Activate reviewed image alias")
        switched = True
        run(COMPOSE_COMMAND + ["up", "-d", "--no-deps", "--no-build", "--pull", "never", "--force-recreate", "backend"], "Backend-only recreation", timeout=120)
        health = wait_for_health(candidate_id)
        internally_healthy = True
        with urllib.request.urlopen("https://voicetype.y.dog/health", timeout=15) as response:
            public_health = json.load(response)
        with urllib.request.urlopen("https://voicetype.y.dog/health/ready", timeout=15) as response:
            public_ready = json.load(response)
        check(public_health.get("ok") is True and public_health.get("database") == "postgres" and verify_readiness(public_ready), "Public health/readiness verification failed.")
        for service in ("postgres", "caddy"):
            current = inspect_container(service)
            check(current["Id"] == initial[service]["Id"] and current["State"]["StartedAt"] == initial[service]["State"]["StartedAt"], "A non-backend service changed during deployment.")
        check(digest(APP / "backend/main.py") == PAYLOAD["main.py"], "Installed source verification failed.")
        private_write(backup / "success.json", json.dumps({"image": candidate_id, "internal": health, "public": public_ready}, indent=2).encode())
        print("Backend-only deployment verified; PostgreSQL and Caddy were not recreated.")
    except Exception:
        if switched and not internally_healthy:
            try:
                current = inspect_container("backend")
                labels = current["Config"].get("Labels") or {}
                if current["Image"] == candidate_id and labels.get("com.docker.compose.project") == "gcp-vm" and labels.get("com.docker.compose.service") == "backend":
                    run(["docker", "stop", "--time", "30", current["Id"]], "Stop only the failed candidate", timeout=45)
                    print("Failed candidate backend stopped. No automatic rollback or database restore was performed.")
            except Exception:
                print("Could not confirm candidate stop; deploy owner must inspect backend status immediately.")
        elif switched:
            print("Candidate passed internal health/readiness and remains running; external verification requires review.")
        if backup:
            print("Evidence retained at " + str(backup) + "; preserve the stable signup key during any manual recovery.")
        raise
    finally:
        os.close(lock_fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--execute", action="store_true", help="Deploy owner only: perform reviewed VM-local deployment after QA succeeds.")
    parser.add_argument("--candidate-image-id", help="Explicit confirmation of the exact QA-approved candidate image ID.")
    args = parser.parse_args()
    if not args.execute:
        print("DRY RUN: no subprocesses, remote access, file writes, image tags, or service changes.")
        print("Target: voicetype-api; Compose project gcp-vm; " + str(COMPOSE))
        print("Candidate payload: " + str(CANDIDATE) + "; main.py SHA256 " + PAYLOAD["main.py"])
        print("Candidate image must pass QA first: " + IMAGE_TAG + " / " + CANDIDATE_IMAGE)
        print("Plan: verify fixed baseline → private unique build20 backup of image/source/env/database → fully read verified dump → provision only missing stable signup key → install three pinned source files → retag exact approved image → recreate only backend → internal/public health and readiness.")
        print("Failure after switching: stop only a candidate that has not passed internal health/readiness; keep an internally healthy candidate running if a later public/network check fails. The old 4bc9 backend has v1 idempotency but does not understand v2 fingerprints, welcome markers, refunds or authoritative decoded duration. Schema compatibility alone does not make rollback safe. Never automatically restore a database dump over newer ledger writes. Keep any newly provisioned identity key permanently.")
        print("Unknowns fail closed at execute: hostname, paths/symlinks, container identities, Compose ownership/config, live/image/payload hashes, database identity/version, available disk, existing dotenv key ambiguity, and all readiness checks.")
        return 0
    try:
        check(args.candidate_image_id == CANDIDATE_IMAGE, "Supply the exact candidate image ID only after its QA is approved.")
        execute(args.candidate_image_id)
    except DeploymentFailure as error:
        print("ABORTED: " + str(error), file=sys.stderr)
        return 1
    except Exception as error:
        print("ABORTED: " + type(error).__name__ + "; sensitive details withheld. No automatic database restore.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
