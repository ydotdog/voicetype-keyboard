"""Launch gaps reproduced with isolated accounts and real bounded audio decoding."""

import asyncio
import io
import shutil
import subprocess
import wave
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from threading import BoundedSemaphore, Event

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from test_billing import auth, load_main, load_production_main
from test_reliability import fund, transcribe, transcribe_key


def wav_audio(seconds=1, rate=8000):
    output = io.BytesIO()
    with wave.open(output, "wb") as clip:
        clip.setnchannels(1)
        clip.setsampwidth(2)
        clip.setframerate(rate)
        clip.writeframes(b"\xe8\x03" * int(seconds * rate))
    return output.getvalue()


def test_same_apple_identity_cannot_reclaim_welcome_credit_after_deletion(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.SIGNUP_GRANT_ENABLED = True
    with TestClient(main.app) as client:
        first = auth(client, "alice")
        assert first["payload"]["balance"]["balance_usd_micros"] == 100_000
        assert client.delete("/v1/account", headers=first["headers"]).status_code == 200
        again = auth(client, "alice")
        bob = auth(client, "bob")
        assert again["payload"]["user"]["id"] != first["payload"]["user"]["id"]
        assert again["payload"]["balance"]["balance_usd_micros"] == 0
        assert bob["payload"]["balance"]["balance_usd_micros"] == 100_000
        with main.db() as conn:
            markers = [dict(row) for row in conn.execute("SELECT * FROM signup_grant_claims")]
            assert len(markers) == 2
            assert set(markers[0]) == {"identity_hash", "granted_at"}
            assert all(len(row["identity_hash"]) == 64 for row in markers)


def test_welcome_marker_and_credit_roll_back_together(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.SIGNUP_GRANT_ENABLED = True
    original = main.insert_ledger
    def fail_grant(*args, **kwargs):
        raise RuntimeError("injected ledger outage")
    monkeypatch.setattr(main, "insert_ledger", fail_grant)
    with TestClient(main.app) as client:
        first = auth(client, "alice")
        assert first["payload"]["balance"]["balance_usd_micros"] == 0
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM signup_grant_claims").fetchone()[0] == 0
        monkeypatch.setattr(main, "insert_ledger", original)
        again = auth(client, "alice")
        assert again["payload"]["balance"]["balance_usd_micros"] == 100_000


def test_existing_welcome_grants_are_backfilled_before_account_deletion(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.SIGNUP_GRANT_ENABLED = True
    with TestClient(main.app) as client:
        first = auth(client, "alice")
        with main.db() as conn:
            conn.execute("DROP TABLE signup_grant_claims")
        main.init_db()
        main.init_db()
        assert client.delete("/v1/account", headers=first["headers"]).status_code == 200
        again = auth(client, "alice")
        assert again["payload"]["balance"]["balance_usd_micros"] == 0


def test_concurrent_welcome_grants_commit_once(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        main.SIGNUP_GRANT_ENABLED = True
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(main.grant_signup_credit_if_needed, [user["payload"]["user"]["id"]] * 4))
        balance = client.get("/v1/me", headers=user["headers"]).json()["balance"]["balance_usd_micros"]
        assert balance == 100_000
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM signup_grant_claims").fetchone()[0] == 1


def test_production_welcome_credit_requires_dedicated_stable_key(tmp_path, monkeypatch):
    main = load_production_main(tmp_path, monkeypatch)
    main.SIGNUP_GRANT_ENABLED = True
    main.SIGNUP_GRANT_HMAC_SECRET = ""
    with TestClient(main.app) as client:
        response = client.get("/health/ready")
    assert response.status_code == 503
    assert response.json()["checks"]["signup_grant_stable_secret"] is False
    with pytest.raises(RuntimeError):
        main.signup_grant_identity_hash("alice")
    main.SIGNUP_GRANT_HMAC_SECRET = "stable-secret"
    before = main.signup_grant_identity_hash("alice")
    main.JWT_SECRET = "rotated-session-secret"
    assert main.signup_grant_identity_hash("alice") == before


def test_reported_provider_duration_overrides_forged_client_seconds(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    async def provider(*args, **kwargs):
        return {"text": "Full recording", "usage": {"type": "duration", "seconds": 600}}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = client.post("/v1/transcriptions", headers=user["headers"],
            data={"audio_seconds": "0", "model": "whisper-1"},
            files={"file": ("clip.wav", b"fake", "audio/wav")})
    assert response.status_code == 200, response.text
    assert response.json()["charge"]["cost_usd_micros"] == 102_858


def test_real_duration_is_reserved_before_provider_even_if_client_reports_zero(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def measured(audio):
        return 600.0
    async def provider(*args, **kwargs):
        calls.append(True)
        return {"text": "must not be called"}
    monkeypatch.setattr(main, "measure_audio_duration", measured)
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user, 20_000)
        response = client.post("/v1/transcriptions", headers=user["headers"],
            data={"audio_seconds": "0"}, files={"file": ("clip.wav", b"fake", "audio/wav")})
    assert response.status_code == 402
    assert calls == []


def test_valid_zero_provider_tokens_do_not_invent_usage_or_charge(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    async def provider(*args, **kwargs):
        return {"text": "No billable tokens", "usage": {"type": "tokens", "input_tokens": 0, "output_tokens": 0}}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = transcribe(client, user)
    assert response.status_code == 200
    assert response.json()["charge"]["cost_usd_micros"] == 0
    assert response.json()["charge"]["pricing_basis"] == "reported_usage"
    assert response.json()["balance"]["balance_usd_micros"] == 1_000_000


@pytest.mark.parametrize("duration", [-1, True, "600", float("nan"), float("inf")])
def test_invalid_provider_duration_is_not_billable(tmp_path, monkeypatch, duration):
    main = load_main(tmp_path, monkeypatch)
    with pytest.raises(HTTPException) as error:
        main.provider_audio_duration({"usage": {"type": "duration", "seconds": duration}}, 1)
    assert error.value.status_code == 502


@pytest.mark.parametrize("model,expected", [
    ("whisper-1", {"response_format": "verbose_json"}),
    ("gpt-4o-transcribe-diarize", {"chunking_strategy": "auto"}),
])
def test_provider_request_uses_supported_model_options(tmp_path, monkeypatch, model, expected):
    main = load_main(tmp_path, monkeypatch)
    main.OPENAI_API_KEY = "fake-key"
    requests = []
    def respond(request):
        requests.append(request.read())
        return httpx.Response(200, json={"text": "hello", "usage": {"type": "duration", "seconds": 1}})
    original = httpx.AsyncClient
    monkeypatch.setattr(main.httpx, "AsyncClient", lambda **kw: original(transport=httpx.MockTransport(respond), **kw))
    asyncio.run(main.transcribe_audio(b"fake audio", "clip.wav", "audio/wav", model, None))
    for key, value in expected.items():
        assert f'name="{key}"\r\n\r\n{value}'.encode() in requests[0]


def test_real_wav_and_aac_are_decoded_without_client_duration(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch, validate_audio=True)
    audio = wav_audio(2)
    assert asyncio.run(main.measure_audio_duration(audio)) == pytest.approx(2, abs=0.01)
    wav_path, aac_path = tmp_path / "valid.wav", tmp_path / "valid.m4a"
    wav_path.write_bytes(audio)
    subprocess.run([shutil.which("ffmpeg"), "-v", "quiet", "-i", str(wav_path),
        "-c:a", "aac", str(aac_path)], check=True, timeout=10)
    assert asyncio.run(main.measure_audio_duration(aac_path.read_bytes())) == pytest.approx(2, abs=0.2)


@pytest.mark.parametrize("audio", [b"not audio", b"#EXTM3U\nhttps://example.invalid/secret.mp3\n"])
def test_invalid_or_playlist_upload_is_rejected_without_provider(tmp_path, monkeypatch, audio):
    main = load_main(tmp_path, monkeypatch, validate_audio=True)
    async def provider(*args, **kwargs):
        pytest.fail("Invalid audio must never reach provider")
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = transcribe(client, user, audio)
        assert response.status_code == 400
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM credit_reservations").fetchone()[0] == 0


def test_overlong_actual_audio_is_rejected(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch, validate_audio=True)
    main.MAX_AUDIO_SECONDS = 1
    with pytest.raises(HTTPException) as error:
        asyncio.run(main.measure_audio_duration(wav_audio(2)))
    assert error.value.status_code == 400


def test_dead_worker_claim_recovers_after_five_minutes(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    entered, release = Event(), Event()
    calls = []
    async def provider(*args, **kwargs):
        calls.append(True)
        if len(calls) == 1:
            entered.set()
            while not release.is_set():
                await asyncio.sleep(0.01)
        return {"text": "same clip"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client, ThreadPoolExecutor(max_workers=1) as pool:
        user = auth(client, "alice")
        fund(client, user)
        old = pool.submit(transcribe_key, client, user, "dead-worker")
        try:
            assert entered.wait(5)
            with main.db() as conn:
                conn.execute("UPDATE transcription_requests SET updated_at = ?", ((datetime.now(timezone.utc) - timedelta(seconds=301)).isoformat(),))
            recovered = transcribe_key(client, user, "dead-worker")
            assert recovered.status_code == 200
        finally:
            release.set()
        assert old.result(5).status_code == 409
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM credit_ledger WHERE kind = 'transcription'").fetchone()[0] == 1


def test_provider_total_deadline_releases_hold_and_request_claim(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.PROVIDER_REQUEST_TIMEOUT_SECONDS = 0.01
    async def provider(*args, **kwargs):
        await asyncio.sleep(10)
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = transcribe_key(client, user, "timeout")
        assert response.status_code == 502
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM credit_reservations").fetchone()[0] == 0
            assert conn.execute("SELECT COUNT(*) FROM transcription_requests").fetchone()[0] == 0


def test_global_work_limit_rejects_excess_before_decode(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main._transcription_slots = BoundedSemaphore(1)
    assert main._transcription_slots.acquire(blocking=False)
    async def decoder(audio):
        pytest.fail("Busy rejection must happen before decode")
    monkeypatch.setattr(main, "measure_audio_duration", decoder)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        response = transcribe(client, user)
    assert response.status_code == 503
    assert response.headers["Retry-After"] == "3"
    main._transcription_slots.release()


def test_decoder_timeout_kills_child_and_releases_work_slot(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch, validate_audio=True)
    main.AUDIO_DECODE_TIMEOUT_SECONDS = 0.01
    main._transcription_slots = BoundedSemaphore(1)
    class StalledDecoder:
        returncode = None
        killed = False
        async def communicate(self):
            if self.killed:
                return b"", b""
            await asyncio.sleep(10)
        def kill(self):
            self.killed = True
            self.returncode = -9
    child = StalledDecoder()
    async def start(*args, **kwargs):
        return child
    monkeypatch.setattr(main.asyncio, "create_subprocess_exec", start)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        response = transcribe(client, user, wav_audio())
    assert response.status_code == 400
    assert child.killed
    assert main._transcription_slots.acquire(blocking=False)
    main._transcription_slots.release()


@pytest.mark.parametrize("legacy", [False, True])
def test_completed_retry_survives_changed_server_default_model(tmp_path, monkeypatch, legacy):
    import hashlib
    import json
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append(args[3])
        return {"text": "original model result"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        first = transcribe_key(client, user, "same-clip")
        assert first.status_code == 200
        if legacy:
            fingerprint = hashlib.sha256(b"fake audio" + json.dumps(
                [main.OPENAI_TRANSCRIBE_MODEL, None, 1.0], separators=(",", ":")).encode()).hexdigest()
            with main.db() as conn:
                conn.execute("UPDATE transcription_requests SET fingerprint = ?, fingerprint_version = 1, selected_model = NULL", (fingerprint,))
        main.OPENAI_TRANSCRIBE_MODEL = "gpt-4o-transcribe"
        replay = transcribe_key(client, user, "same-clip")
        assert replay.status_code == 200, replay.text
        assert replay.json() == first.json()
        assert calls == ["gpt-4o-mini-transcribe"]


@pytest.mark.parametrize("legacy", [False, True])
def test_stale_retry_keeps_original_selected_model_after_default_change(tmp_path, monkeypatch, legacy):
    import hashlib
    import json
    main = load_main(tmp_path, monkeypatch)
    entered, release = Event(), Event()
    calls = []
    async def provider(*args, **kwargs):
        calls.append(args[3])
        if len(calls) == 1:
            entered.set()
            while not release.is_set():
                await asyncio.sleep(0.01)
        return {"text": "original model result"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client, ThreadPoolExecutor(max_workers=1) as pool:
        user = auth(client, "alice")
        fund(client, user)
        old = pool.submit(transcribe_key, client, user, "same-clip")
        try:
            assert entered.wait(5)
            with main.db() as conn:
                conn.execute("UPDATE transcription_requests SET updated_at = ?", ((datetime.now(timezone.utc) - timedelta(seconds=301)).isoformat(),))
                if legacy:
                    fingerprint = hashlib.sha256(b"fake audio" + json.dumps(
                        [main.OPENAI_TRANSCRIBE_MODEL, None, 1.0], separators=(",", ":")).encode()).hexdigest()
                    conn.execute("UPDATE transcription_requests SET fingerprint = ?, fingerprint_version = 1, selected_model = NULL", (fingerprint,))
            main.OPENAI_TRANSCRIBE_MODEL = "gpt-4o-transcribe"
            recovered = transcribe_key(client, user, "same-clip")
            assert recovered.status_code == 200, recovered.text
            assert recovered.json()["model"] == "gpt-4o-mini-transcribe"
        finally:
            release.set()
        assert old.result(5).status_code == 409
        assert calls == ["gpt-4o-mini-transcribe"] * 2


def test_explicit_model_change_conflicts_with_same_semantic_request_key(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    async def provider(*args, **kwargs):
        return {"text": "same"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        assert transcribe_key(client, user, "same-clip").status_code == 200
        changed = client.post("/v1/transcriptions", headers={**user["headers"], "Idempotency-Key": "same-clip"},
            data={"audio_seconds": "1", "model": "gpt-4o-transcribe"},
            files={"file": ("clip.m4a", b"fake audio", "audio/m4a")})
    assert changed.status_code == 409
