#!/usr/bin/env python3
"""Run release checks only in an existing, isolated PostgreSQL QA database.

Mount/copy this script into the newly built backend image and run it from /app:
    python /tmp/verify_postgres_release.py --database-name voicetype_release_qa_20260913

DATABASE_URL supplies connection credentials; its database path is replaced
before main is imported. All testing overrides affect this process only. The
script does not create/drop databases or modify deployment configuration.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import secrets
import sys
from concurrent.futures import ThreadPoolExecutor
from threading import Event
import time
from urllib.parse import parse_qsl, quote, urlsplit, urlunsplit
import uuid


class VerificationFailure(Exception):
    """Contains a fixed diagnostic, never a connection string or response body."""


def check(condition: bool, description: str) -> None:
    if not condition:
        raise VerificationFailure(description)


def qa_database_url(database_name: str) -> str:
    check(
        bool(re.fullmatch(r"voicetype_release_qa_[a-z0-9_]+", database_name))
        and len(database_name) <= 63,
        "Database name must use the voicetype_release_qa_ prefix.",
    )
    original = os.environ.get("DATABASE_URL", "")
    check(bool(original), "DATABASE_URL is required; its value is never printed.")
    parsed = urlsplit(original)
    check(parsed.scheme in {"postgres", "postgresql"}, "A PostgreSQL URL is required.")
    check(bool(parsed.hostname), "The PostgreSQL URL must name its host.")
    query_keys = {key.lower() for key, _ in parse_qsl(parsed.query)}
    check(
        not query_keys.intersection({"dbname", "database", "service", "options"}),
        "Connection query must not override the database, service, or SQL options.",
    )
    return urlunsplit((parsed.scheme, parsed.netloc, "/" + quote(database_name), parsed.query, ""))


def configure_qa_process(database_url: str) -> None:
    os.environ.update({
        "DATABASE_URL": database_url,
        "DATABASE_POOL_MAX_SIZE": "8",
        "JWT_SECRET": secrets.token_urlsafe(32),
        "APPLE_AUTH_DEV_BYPASS": "true",
        "ALLOW_DEV_CREDIT": "true",
        "DEV_CREDIT_SHARED_SECRET": "",
        "STOREKIT_VERIFICATION_MODE": "development",
        "ALLOW_UNVERIFIED_STOREKIT_JWS": "true",
        "REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN": "true",
        "APPLE_SIGNIN_TEAM_ID": "",
        "APPLE_SIGNIN_KEY_ID": "",
        "APPLE_SIGNIN_PRIVATE_KEY": "",
        "APPLE_SIGNIN_PRIVATE_KEY_PATH": "",
        "APPLE_SIGNIN_PRIVATE_KEY_B64": "",
        "APPLE_TOKEN_URL": "http://127.0.0.1:1/qa-disabled",
        "APPLE_REVOKE_URL": "http://127.0.0.1:1/qa-disabled",
        "OPENAI_API_KEY": "qa-provider-is-mocked",
        "OPENAI_BASE_URL": "http://127.0.0.1:1/qa-disabled",
        "OPENAI_TRANSCRIBE_MODEL": "gpt-4o-mini-transcribe",
        "SIGNUP_GRANT_ENABLED": "false",
        "SIGNUP_GRANT_HMAC_SECRET": "qa-only-stable-identity-key-never-use-in-production",
        "RATE_LIMIT_ENABLED": "false",
        "COST_MARKUP_BPS": "7143",
        "MIN_TRANSCRIPTION_RESERVATION_USD_MICROS": "20000",
        "CREDIT_RESERVATION_TTL_SECONDS": "1800",
        "LOG_LEVEL": "ERROR",
    })


def verify(database_name: str) -> None:
    import psycopg

    database_url = qa_database_url(database_name)
    # Verify the resolved target before importing main or running any schema SQL.
    with psycopg.connect(database_url, connect_timeout=10) as conn:
        actual_name = conn.execute("SELECT current_database()").fetchone()[0]
        check(actual_name == database_name, "Connection did not resolve to the requested QA database.")
        version = int(conn.execute("SHOW server_version_num").fetchone()[0])
        check(version // 10000 == 16, "Expected PostgreSQL 16 for this release check.")

    configure_qa_process(database_url)
    check("main" not in sys.modules, "Backend must not be imported before QA isolation is configured.")
    for directory in (Path.cwd(), Path(__file__).resolve().parents[1] / "backend"):
        if (directory / "main.py").is_file():
            sys.path.insert(0, str(directory))
            break
    backend = importlib.import_module("main")
    from fastapi.testclient import TestClient

    check(backend.is_postgres(), "Backend is not using PostgreSQL.")
    check(backend.DATABASE_URL == database_url, "Backend database configuration does not match QA.")

    provider_calls: list[bytes] = []
    provider_entered, provider_release = Event(), Event()

    async def fake_transcribe(audio, *args, **kwargs):
        provider_calls.append(audio)
        if audio == b"concurrent QA clip":
            provider_entered.set()
            deadline = time.monotonic() + 10
            while not provider_release.is_set():
                check(time.monotonic() < deadline, "Concurrent request test exceeded its deadline.")
                await asyncio.sleep(0.01)
        return {"text": "QA transcription", "usage": {"input_tokens": 1000, "output_tokens": 100}}

    backend.transcribe_audio = fake_transcribe
    # This script tests database transactions using opaque synthetic clips;
    # actual decoder/valid-media coverage is in the backend test suite.
    async def fake_audio_duration(audio):
        return 1.0
    backend.measure_audio_duration = fake_audio_duration
    run_id = uuid.uuid4().hex

    def sign_in(client, name):
        response = client.post("/v1/auth/apple", json={"identity_token": f"dev:qa-{run_id}-{name}"})
        check(response.status_code == 200, "QA Apple dev sign-in failed.")
        payload = response.json()
        return payload["user"]["id"], {"Authorization": f"Bearer {payload['token']}"}

    def fund(client, headers, amount):
        response = client.post("/v1/billing/dev-credit", headers=headers, json={"amount_usd_micros": amount})
        check(response.status_code == 200, "QA credit grant failed.")

    def balance(client, headers):
        response = client.get("/v1/me", headers=headers)
        check(response.status_code == 200, "QA balance request failed.")
        return response.json()["balance"]["balance_usd_micros"]

    def transcription(client, headers, key, audio=b"completed QA clip"):
        return client.post(
            "/v1/transcriptions",
            headers={**headers, "Idempotency-Key": key},
            data={"audio_seconds": "1"},
            files={"file": ("qa.m4a", audio, "audio/m4a")},
        )

    completed_key, concurrent_key = uuid.uuid4().hex, uuid.uuid4().hex
    with TestClient(backend.app) as client:
        # Startup already initialized/migrated the schema; run it again to prove
        # the same SQL is safe on an existing database.
        backend.init_db()
        with backend.db() as conn:
            check(conn.execute("SELECT current_database()").fetchone()["current_database"] == database_name, "Backend pool escaped QA database.")
            table = conn.execute("SELECT to_regclass('public.transcription_requests') AS name").fetchone()
            check(table["name"] is not None, "Idempotency migration did not create its table.")
        alice_id, alice_headers = sign_in(client, "alice")
        bob_id, bob_headers = sign_in(client, "bob")
        check(alice_id != bob_id, "Independent Apple identities were combined.")
        fund(client, alice_headers, 1_000_000)
        fund(client, bob_headers, 2_000_000)
        check(balance(client, alice_headers) == 1_000_000, "Alice ledger balance is incorrect.")
        check(balance(client, bob_headers) == 2_000_000, "Bob ledger balance is incorrect.")

        locked, unlock = Event(), Event()

        def hold_alice_lock():
            with backend.db() as conn:
                backend.lock_user(conn, alice_id)
                locked.set()
                check(unlock.wait(timeout=10), "User-lock test exceeded its deadline.")

        with ThreadPoolExecutor(max_workers=1) as pool:
            holder = pool.submit(hold_alice_lock)
            try:
                check(locked.wait(timeout=5), "Could not acquire first user lock.")
                with backend.db() as conn:
                    conn.execute("SET LOCAL lock_timeout = '300ms'")
                    backend.lock_user(conn, bob_id)
                same_user_blocked = False
                try:
                    with backend.db() as conn:
                        conn.execute("SET LOCAL lock_timeout = '300ms'")
                        backend.lock_user(conn, alice_id)
                except psycopg.errors.LockNotAvailable:
                    same_user_blocked = True
                check(same_user_blocked, "A second transaction bypassed the per-user lock.")
            finally:
                unlock.set()
            holder.result(timeout=5)

        first = transcription(client, alice_headers, completed_key)
        check(first.status_code == 200, "Initial transcription failed.")
        first_payload = first.json()
        check(first_payload["charge"]["cost_usd_micros"] == 3001, "Transcription charge changed unexpectedly.")
        fund(client, alice_headers, 500_000)
        replay = transcription(client, alice_headers, completed_key)
        check(replay.status_code == 200, "Completed transcription replay failed.")
        check(replay.json()["id"] == first_payload["id"], "Replay created another transcription.")
        check(replay.json()["balance"]["balance_usd_micros"] == 1_496_999, "Replay did not return the current balance.")
        check(len(provider_calls) == 1, "Completed replay called the provider again.")
        backend.OPENAI_TRANSCRIBE_MODEL = "gpt-4o-transcribe"
        changed_default_replay = transcription(client, alice_headers, completed_key)
        check(changed_default_replay.status_code == 200, "Default model change broke completed replay.")
        check(changed_default_replay.json()["model"] == "gpt-4o-mini-transcribe", "Replay changed the original model.")
        backend.OPENAI_TRANSCRIBE_MODEL = "gpt-4o-mini-transcribe"
        check(balance(client, bob_headers) == 2_000_000, "Alice transcription changed Bob's ledger.")

        with ThreadPoolExecutor(max_workers=1) as pool:
            running = pool.submit(transcription, client, alice_headers, concurrent_key, b"concurrent QA clip")
            try:
                check(provider_entered.wait(timeout=5), "First concurrent request never reached the provider.")
                duplicate = transcription(client, alice_headers, concurrent_key, b"concurrent QA clip")
                check(duplicate.status_code == 409, "Concurrent duplicate was not rejected.")
                check(1 <= int(duplicate.headers.get("Retry-After", "0")) <= backend.TRANSCRIPTION_PROCESSING_LEASE_SECONDS, "Concurrent duplicate lacked retry guidance.")
                check(len(provider_calls) == 2, "Concurrent duplicate called the provider twice.")
            finally:
                provider_release.set()
            completed = running.result(timeout=5)
        check(completed.status_code == 200, "Original concurrent request did not complete.")
        completed_payload = completed.json()
        with backend.db() as conn:
            counts = conn.execute(
                "SELECT COUNT(*) AS count FROM credit_ledger WHERE user_id = %s AND kind = 'transcription'",
                (alice_id,),
            ).fetchone()
            check(counts["count"] == 2, "Expected one debit for each of two unique recordings.")
            holds = conn.execute("SELECT COUNT(*) AS count FROM credit_reservations WHERE user_id = %s", (alice_id,)).fetchone()
            check(holds["count"] == 0, "A completed request left credit reserved.")

        backend.SIGNUP_GRANT_ENABLED = True
        welcome_id, welcome_headers = sign_in(client, "welcome")
        check(balance(client, welcome_headers) == 100_000, "First welcome grant failed.")
        # Simulate a pre-marker account, then migrate twice before deletion.
        marker = backend.signup_grant_identity_hash(f"qa-{run_id}-welcome")
        with backend.db() as conn:
            conn.execute("DELETE FROM signup_grant_claims WHERE identity_hash = %s", (marker,))
        backend.init_db()
        backend.init_db()
        check(client.delete("/v1/account", headers=welcome_headers).status_code == 200, "QA account deletion failed.")
        recreated_id, recreated_headers = sign_in(client, "welcome")
        check(recreated_id != welcome_id, "Deleted account was not recreated independently.")
        check(balance(client, recreated_headers) == 0, "Recreated Apple identity reclaimed welcome credit.")
        backend.SIGNUP_GRANT_ENABLED = False

        refund_id, refund_headers = sign_in(client, "refund")
        transaction = {
            "productId": "com.kyleqi.voicetype.credits.small", "transactionId": f"qa-{run_id}-refund",
            "bundleId": backend.APPLE_BUNDLE_ID, "environment": "LocalTesting",
            "appAccountToken": refund_id, "type": "Consumable", "quantity": 1,
        }
        def fake_jws(payload):
            encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=").decode()
            return f"eyJhbGciOiJub25lIn0.{encoded}.qa-signature"
        def deliver_purchase(payload):
            return client.post("/v1/billing/storekit/transactions", headers=refund_headers,
                json={"signed_transaction": fake_jws(payload)})
        def refund_event(payload, kind, signed_date):
            signed_transaction = dict(payload)
            if kind == "REFUND":
                signed_transaction["revocationDate"] = signed_date
            return {"notification_id": f"{payload['transactionId']}-{kind}-{signed_date}",
                "notification_type": kind, "signed_date": signed_date, "environment": "LocalTesting",
                "signed_transaction": fake_jws(signed_transaction)}
        # QA simulates verified notification input; cryptographic verification
        # is exercised by the local signed-certificate backend test.
        current_event = refund_event(transaction, "REFUND", 1000)
        original_verifier = backend.verify_storekit_notification
        backend.verify_storekit_notification = lambda signed: current_event
        def notify_refund():
            return client.post("/v1/billing/storekit/notifications", json={"signedPayload": "qa-verified-notification"})
        try:
            check(deliver_purchase(transaction).status_code == 200, "QA purchase credit failed.")
            with backend.db() as conn:
                backend.insert_ledger(conn, user_id=refund_id, amount_usd_micros=-50_000,
                    kind="transcription", description="QA consumption", source_id=f"qa-consumption:{run_id}")
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda _: notify_refund(), range(2)))
            check(all(result.status_code == 200 for result in results), "Concurrent refund notification failed.")
            check(balance(client, refund_headers) == -50_000, "Refund did not reverse the original grant exactly once.")
            current_event = refund_event(transaction, "REFUND_REVERSED", 2000)
            check(notify_refund().status_code == 200, "Refund reversal failed.")
            check(balance(client, refund_headers) == 940_000, "Refund reversal amount is incorrect.")
            current_event = refund_event(transaction, "REFUND", 1500)
            check(notify_refund().status_code == 200 and balance(client, refund_headers) == 940_000, "Older refund overwrote a newer reversal.")
            pending = {**transaction, "transactionId": f"qa-{run_id}-pending-refund"}
            current_event = refund_event(pending, "REFUND", 1000)
            check(notify_refund().status_code == 200, "Pre-delivery refund state failed.")
            check(deliver_purchase(pending).status_code == 400, "Refunded purchase was granted after late client delivery.")
            current_event = refund_event(pending, "REFUND_REVERSED", 2000)
            check(notify_refund().status_code == 200, "Pre-delivery reversal failed.")
            check(deliver_purchase(pending).status_code == 200, "Reversed pending purchase could not be delivered.")
            check(client.delete("/v1/account", headers=refund_headers).status_code == 200, "Refund account deletion failed.")
            check(notify_refund().json().get("ignored") is True, "Deleted account was affected by a later notification.")
            with backend.db() as conn:
                for table in ("storekit_refund_states", "storekit_notification_events"):
                    check(conn.execute(f"SELECT COUNT(*) AS count FROM {table} WHERE user_id = %s", (refund_id,)).fetchone()["count"] == 0,
                        "Account deletion retained refund state.")
        finally:
            backend.verify_storekit_notification = original_verifier

    # Recreate the connection pool/application lifespan and read the durable result.
    with TestClient(backend.app) as client:
        replay = transcription(client, alice_headers, concurrent_key, b"concurrent QA clip")
        check(replay.status_code == 200, "Replay after backend restart failed.")
        check(replay.json()["id"] == completed_payload["id"], "Restart lost the completed request identity.")
        check(len(provider_calls) == 2, "Replay after restart called the provider again.")
        check(balance(client, alice_headers) == 1_493_998, "Final debit total is incorrect.")

    source_hash = hashlib.sha256(Path(backend.__file__).read_bytes()).hexdigest()[:12]
    print(f"PASS PostgreSQL 16 QA ({database_name}); backend {source_hash}")
    print("PASS migration twice; isolated accounts/ledgers; per-user row locks")
    print("PASS completed replay/current balance; concurrent duplicate/one debit; restart replay")
    print("PASS model-default replay; welcome backfill/delete/recreate; concurrent refund/reversal/order; pending delivery; deletion cascade")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database-name", required=True)
    args = parser.parse_args()
    try:
        verify(args.database_name)
        return 0
    except VerificationFailure as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
    except Exception as exc:
        # Database/client exception strings may contain credentials. Emit only
        # the exception class and keep all connection details out of the output.
        print(f"FAIL: release verification raised {type(exc).__name__}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
