"""Behavioral regression coverage for account, purchase and transcription failures."""

import asyncio
import io
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi import HTTPException, UploadFile
from fastapi.testclient import TestClient

from test_billing import auth, fake_jws, load_main, load_production_main


def fund(client, user, amount=1_000_000):
    response = client.post(
        "/v1/billing/dev-credit", headers=user["headers"],
        json={"amount_usd_micros": amount},
    )
    assert response.status_code == 200, response.text


def transcribe(client, user, audio=b"fake audio"):
    return client.post(
        "/v1/transcriptions", headers=user["headers"],
        data={"audio_seconds": "1"}, files={"file": ("clip.m4a", audio, "audio/m4a")},
    )


def test_random_authorization_headers_cannot_bypass_signin_limit(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.AUTH_RATE_LIMIT_PER_WINDOW = 1
    with TestClient(main.app) as client:
        first = client.post("/v1/auth/apple", headers={"Authorization": "Bearer random-1"}, json={"identity_token": "dev:alice"})
        second = client.post("/v1/auth/apple", headers={"Authorization": "Bearer random-2"}, json={"identity_token": "dev:bob"})
    assert first.status_code == 200
    assert second.status_code == 429


def test_new_session_token_uses_same_account_rate_limit(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.BILLING_RATE_LIMIT_PER_WINDOW = 1
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = main.decode_session_token(user["payload"]["token"])
        payload["jti"] = "another-login"
        another_token = main.jwt.encode(payload, main.JWT_SECRET, algorithm="HS256")
        first = client.get("/v1/billing/products", headers=user["headers"])
        second = client.get("/v1/billing/products", headers={"Authorization": f"Bearer {another_token}"})
    assert first.status_code == 200
    assert second.status_code == 429


def test_session_without_expiration_is_rejected(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = main.decode_session_token(user["payload"]["token"])
        payload.pop("exp")
        token = main.jwt.encode(payload, main.JWT_SECRET, algorithm="HS256")
        response = client.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401


@pytest.mark.parametrize("changes", [
    {"revocationDate": 123456789}, {"quantity": 2}, {"type": "Auto-Renewable Subscription"},
])
def test_unusable_storekit_transaction_does_not_grant_credit(tmp_path, monkeypatch, changes):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        transaction = {
            "productId": "com.kyleqi.voicetype.credits.small", "transactionId": "tx-rejected",
            "bundleId": main.APPLE_BUNDLE_ID, "appAccountToken": user["payload"]["user"]["id"],
            **changes,
        }
        response = client.post("/v1/billing/storekit/transactions", headers=user["headers"], json={"signed_transaction": fake_jws(transaction)})
        balance = client.get("/v1/me", headers=user["headers"])
    assert response.status_code == 400
    assert balance.json()["balance"]["balance_usd_micros"] == 0


def test_strict_storekit_never_trusts_unsigned_local_transaction(tmp_path, monkeypatch):
    main = load_production_main(tmp_path, monkeypatch)
    main.APPLE_STOREKIT_ENVIRONMENT = "XCODE"
    main.STOREKIT_ACCEPTED_ENVIRONMENTS = "XCODE,LOCAL_TESTING,PRODUCTION,SANDBOX"
    forged = fake_jws({"environment": "Xcode", "bundleId": main.APPLE_BUNDLE_ID, "transactionId": "fake"})
    with pytest.raises(HTTPException) as error:
        main.verify_storekit_payload(forged)
    assert error.value.status_code == 401


def test_invalid_storekit_environment_configuration_fails_closed(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.STOREKIT_ACCEPTED_ENVIRONMENTS = "PRODCUTION"
    with pytest.raises(HTTPException) as error:
        main.ensure_storekit_environment_allowed("Production")
    assert error.value.status_code == 403


def test_non_object_storekit_payload_is_a_bad_request(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with pytest.raises(HTTPException) as error:
        main.decode_unverified_storekit_payload(fake_jws(["not", "a", "transaction"]))
    assert error.value.status_code == 400


@pytest.mark.parametrize("provider_payload", [
    None, {"text": []}, {"text": " "}, {"text": "ok", "usage": [1]},
    {"text": "ok", "usage": {"input_tokens": -5}},
    {"text": "ok", "usage": {"input_tokens": "broken"}},
])
def test_bad_provider_results_release_credit_and_do_not_charge(tmp_path, monkeypatch, provider_payload):
    main = load_main(tmp_path, monkeypatch)
    async def provider(*args, **kwargs):
        return provider_payload
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = transcribe(client, user)
        balance = client.get("/v1/me", headers=user["headers"])
    assert response.status_code == 502, response.text
    assert balance.json()["balance"]["balance_usd_micros"] == 1_000_000
    with main.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM credit_reservations").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM transcriptions").fetchone()[0] == 0


def test_provider_timeout_releases_credit_and_returns_retryable_error(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    async def provider(*args, **kwargs):
        raise httpx.ReadTimeout("provider stalled")
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = transcribe(client, user)
        balance = client.get("/v1/me", headers=user["headers"])
    assert response.status_code == 502
    assert balance.json()["balance"]["balance_usd_micros"] == 1_000_000


def test_expired_hold_cannot_spend_funds_reserved_by_another_request(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    async def provider(*args, **kwargs):
        with main.db() as conn:
            uid = conn.execute("SELECT id FROM users").fetchone()[0]
            expired = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
            conn.execute("UPDATE credit_reservations SET created_at = ?", (expired,))
            main.reserve_credit(conn, user_id=uid, amount_usd_micros=20_000, kind="another_request")
        return {"text": "ok", "usage": {"input_tokens": 1_000, "output_tokens": 100}}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user, 20_000)
        response = transcribe(client, user)
    assert response.status_code == 200, response.text
    assert response.json()["charge"]["cost_usd_micros"] == 0
    assert response.json()["balance"]["balance_usd_micros"] == 0
    with main.db() as conn:
        assert main.ledger_balance_for_user(conn, user["payload"]["user"]["id"]) == 20_000
        assert conn.execute("SELECT COUNT(*) FROM credit_reservations").fetchone()[0] == 1


def test_transcription_cancellation_releases_credit(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    async def provider(*args, **kwargs):
        raise asyncio.CancelledError()
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        with main.db() as conn:
            account = dict(conn.execute("SELECT * FROM users").fetchone())
        file = UploadFile(filename="clip.m4a", file=io.BytesIO(b"fake audio"))
        with pytest.raises(asyncio.CancelledError):
            asyncio.run(main.create_transcription(user=account, file=file, audio_seconds=1))
        balance = client.get("/v1/me", headers=user["headers"])
    assert balance.json()["balance"]["balance_usd_micros"] == 1_000_000


def test_account_deleted_during_transcription_returns_unauthorized(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    async def provider(*args, **kwargs):
        with main.db() as conn:
            conn.execute("DELETE FROM users")
        return {"text": "ok"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = transcribe(client, user)
    assert response.status_code == 401


def test_oversized_audio_never_reaches_provider(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.MAX_AUDIO_BYTES = 8
    async def provider(*args, **kwargs):
        pytest.fail("Oversized audio reached the provider")
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        response = transcribe(client, user, audio=b"x" * 9)
        early_response = transcribe(client, user, audio=b"x" * 70000)
    assert response.status_code == 413
    assert early_response.status_code == 413


def test_failed_apple_revocation_preserves_account_for_retry(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    attempts = []
    def revoke(token):
        attempts.append(token)
        return len(attempts) > 1
    monkeypatch.setattr(main, "revoke_apple_token", revoke)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        with main.db() as conn:
            conn.execute("UPDATE users SET apple_refresh_token = ?", ("refresh-alice",))
        failed = client.delete("/v1/account", headers=user["headers"])
        still_present = client.get("/v1/me", headers=user["headers"])
        succeeded = client.delete("/v1/account", headers=user["headers"])
        removed = client.get("/v1/me", headers=user["headers"])
    assert failed.status_code == 503
    assert still_present.json()["balance"]["balance_usd_micros"] == 1_000_000
    assert succeeded.status_code == 200
    assert succeeded.json()["apple_token_revoked"] is True
    assert removed.status_code == 401
    assert attempts == ["refresh-alice", "refresh-alice"]


@pytest.mark.parametrize("code_user, expected_status", [("alice", 200), ("bob", 401)])
def test_apple_code_exchange_is_bound_to_identity_user(tmp_path, monkeypatch, code_user, expected_status):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "apple_signin_configured", lambda: True)
    monkeypatch.setattr(main, "generate_apple_client_secret", lambda: "test-secret")
    monkeypatch.setattr(main.httpx, "post", lambda *a, **kw: httpx.Response(200, json={"id_token": f"dev:{code_user}", "refresh_token": "refresh-token"}))
    with TestClient(main.app) as client:
        response = client.post("/v1/auth/apple", json={"identity_token": "dev:alice", "authorization_code": "code"})
    assert response.status_code == expected_status, response.text
    with main.db() as conn:
        rows = conn.execute("SELECT apple_refresh_token FROM users").fetchall()
        if expected_status == 200:
            assert rows[0][0] == "refresh-token"
        else:
            assert not rows


def test_apple_exchange_failure_does_not_create_unrevocable_account(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "apple_signin_configured", lambda: True)
    monkeypatch.setattr(main, "generate_apple_client_secret", lambda: "test-secret")
    monkeypatch.setattr(main.httpx, "post", lambda *a, **kw: httpx.Response(503, text="unavailable"))
    with TestClient(main.app) as client:
        response = client.post("/v1/auth/apple", json={"identity_token": "dev:alice", "authorization_code": "code"})
    assert response.status_code == 503
    with main.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0


def transcribe_key(client, user, key, audio=b"fake audio"):
    return client.post(
        "/v1/transcriptions", headers={**user["headers"], "Idempotency-Key": key},
        data={"audio_seconds": "1"}, files={"file": ("clip.m4a", audio, "audio/m4a")},
    )


def test_completed_transcription_retry_survives_restart_and_charges_once(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append(True)
        return {"text": "saved words", "usage": {"input_tokens": 1_000, "output_tokens": 100}}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        first = transcribe_key(client, user, "stable-clip")
    # A new application lifespan uses the persisted result, even when the last
    # response never made it back to the phone before it restarted.
    with TestClient(main.app) as client:
        fund(client, user, 500_000)
        retry = transcribe_key(client, user, "stable-clip")
    assert first.status_code == retry.status_code == 200
    assert retry.json()["id"] == first.json()["id"]
    assert retry.json()["transcript"] == "saved words"
    assert retry.json()["charge"] == first.json()["charge"]
    assert retry.json()["balance"]["balance_usd_micros"] == 1_500_000 - 3_001
    assert len(calls) == 1
    with main.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger WHERE kind = 'transcription'").fetchone()[0] == 1


def test_request_key_cannot_represent_different_recording(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append(True)
        return {"text": "saved words"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        first = transcribe_key(client, user, "stable-clip")
        different = transcribe_key(client, user, "stable-clip", audio=b"another recording")
    assert first.status_code == 200
    assert different.status_code == 409
    assert len(calls) == 1


def test_failed_transcription_can_retry_with_original_request_key(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append(True)
        if len(calls) == 1:
            raise httpx.ReadTimeout("interrupted")
        return {"text": "retry worked"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        first = transcribe_key(client, user, "stable-clip")
        second = transcribe_key(client, user, "stable-clip")
        replay = transcribe_key(client, user, "stable-clip")
    assert first.status_code == 502
    assert second.status_code == replay.status_code == 200
    assert second.json()["id"] == replay.json()["id"]
    assert len(calls) == 2
    with main.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger WHERE kind = 'transcription'").fetchone()[0] == 1


def test_same_request_key_is_independent_between_users(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    async def provider(*args, **kwargs):
        return {"text": "words"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        alice, bob = auth(client, "alice"), auth(client, "bob")
        fund(client, alice)
        fund(client, bob)
        first = transcribe_key(client, alice, "same-key")
        second = transcribe_key(client, bob, "same-key")
    assert first.status_code == second.status_code == 200
    assert first.json()["id"] != second.json()["id"]


def test_concurrent_retry_does_not_start_second_provider_request(tmp_path, monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    main = load_main(tmp_path, monkeypatch)
    entered, release = Event(), Event()
    calls = []
    async def provider(*args, **kwargs):
        calls.append(True)
        entered.set()
        while not release.is_set():
            await asyncio.sleep(0.01)
        return {"text": "completed once"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client, ThreadPoolExecutor(max_workers=1) as pool:
        user = auth(client, "alice")
        fund(client, user)
        first = pool.submit(transcribe_key, client, user, "stable-clip")
        try:
            assert entered.wait(timeout=5)
            retry = transcribe_key(client, user, "stable-clip")
            assert retry.status_code == 409
            assert 1 <= int(retry.headers["Retry-After"]) <= main.TRANSCRIPTION_PROCESSING_LEASE_SECONDS
            assert len(calls) == 1
        finally:
            release.set()
        completed = first.result(timeout=5)
        replay = transcribe_key(client, user, "stable-clip")
    assert completed.status_code == replay.status_code == 200
    assert replay.json()["id"] == completed.json()["id"]
    assert len(calls) == 1


def test_recovered_stale_attempt_prevents_old_worker_from_debiting(tmp_path, monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    main = load_main(tmp_path, monkeypatch)
    entered, release = Event(), Event()
    calls = []
    async def provider(*args, **kwargs):
        calls.append(True)
        if len(calls) == 1:
            entered.set()
            while not release.is_set():
                await asyncio.sleep(0.01)
            return {"text": "old result"}
        return {"text": "new result"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client, ThreadPoolExecutor(max_workers=1) as pool:
        user = auth(client, "alice")
        fund(client, user)
        old_worker = pool.submit(transcribe_key, client, user, "stable-clip")
        try:
            assert entered.wait(timeout=5)
            with main.db() as conn:
                expired = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
                conn.execute("UPDATE transcription_requests SET updated_at = ?", (expired,))
                conn.execute("UPDATE credit_reservations SET created_at = ?", (expired,))
            recovered = transcribe_key(client, user, "stable-clip")
            assert recovered.status_code == 200, recovered.text
        finally:
            release.set()
        original = old_worker.result(timeout=5)
        replay = transcribe_key(client, user, "stable-clip")
    assert original.status_code == 409
    assert replay.json()["transcript"] == "new result"
    assert replay.json()["id"] == recovered.json()["id"]
    with main.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger WHERE kind = 'transcription'").fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM credit_reservations").fetchone()[0] == 0


@pytest.mark.parametrize("mode, allow_unsigned", [("strcit", False), ("development", False), ("strict", True)])
def test_storekit_misconfiguration_never_accepts_unsigned_transactions(tmp_path, monkeypatch, mode, allow_unsigned):
    main = load_main(tmp_path, monkeypatch)
    main.STOREKIT_VERIFICATION_MODE = mode
    main.ALLOW_UNVERIFIED_STOREKIT_JWS = allow_unsigned
    with pytest.raises(HTTPException) as error:
        main.verify_storekit_payload(fake_jws({"transactionId": "forged"}))
    assert error.value.status_code == 500


def test_configured_apple_signin_requires_code_for_new_account(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "apple_signin_configured", lambda: True)
    with TestClient(main.app) as client:
        response = client.post("/v1/auth/apple", json={"identity_token": "dev:alice"})
    assert response.status_code == 400
    assert "sign in with Apple again" in response.json()["detail"]
    with main.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger").fetchone()[0] == 0


def test_configured_apple_signin_requires_code_for_existing_account_without_grant(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        original = auth(client, "alice")
        monkeypatch.setattr(main, "apple_signin_configured", lambda: True)
        response = client.post("/v1/auth/apple", json={"identity_token": "dev:alice"})
        existing = client.get("/v1/me", headers=original["headers"])
    assert response.status_code == 400
    assert existing.status_code == 200
    assert existing.json()["user"]["id"] == original["payload"]["user"]["id"]


def test_existing_apple_grant_allows_signin_without_new_code(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        original = auth(client, "alice")
        with main.db() as conn:
            conn.execute("UPDATE users SET apple_refresh_token = ?", ("previously-exchanged-grant",))
        monkeypatch.setattr(main, "apple_signin_configured", lambda: True)
        response = client.post("/v1/auth/apple", json={"identity_token": "dev:alice"})
    assert response.status_code == 200, response.text
    assert response.json()["user"]["id"] == original["payload"]["user"]["id"]
    with main.db() as conn:
        assert conn.execute("SELECT apple_refresh_token FROM users").fetchone()[0] == "previously-exchanged-grant"
