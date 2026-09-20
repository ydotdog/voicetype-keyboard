#!/usr/bin/env python3
"""Isolated Linux-image audio/load checks and an opt-in synthetic provider call.

Requires an existing voicetype_release_qa_* PostgreSQL database. DATABASE_URL
credentials stay inside the process and the database path is replaced before
importing the backend. Never starts a server, deploys, or uses real user auth.
"""

from __future__ import annotations

import argparse
import asyncio
from concurrent.futures import ThreadPoolExecutor
import difflib
import hashlib
import importlib
import io
import json
import logging
import os
from pathlib import Path
import re
import resource
import sys
from threading import Event
import time
from urllib.parse import urlsplit
import uuid
import wave

from verify_postgres_release import check, configure_qa_process, qa_database_url, VerificationFailure


EXPECTED_TEXT = "This is a VoiceType release test. The microphone session stays available while I start and stop separate recordings."


def normalized_text(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", text.lower())


def cgroup_number(name: str):
    path = Path("/sys/fs/cgroup") / name
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return None


def verify(args) -> None:
    import psycopg
    check(sys.platform == "linux", "Run this check inside the final Linux backend image.")
    audio_path = Path(args.audio_path)
    check(audio_path.is_file() and audio_path.stat().st_size <= 1_000_000, "Expected a small synthetic audio fixture.")
    audio = audio_path.read_bytes()
    check(hashlib.sha256(audio).hexdigest() == args.expected_audio_sha256, "Synthetic audio fixture hash mismatch.")
    database_url = qa_database_url(args.database_name)
    with psycopg.connect(database_url, connect_timeout=10) as conn:
        check(conn.execute("SELECT current_database()").fetchone()[0] == args.database_name, "QA database target mismatch.")
        check(int(conn.execute("SHOW server_version_num").fetchone()[0]) // 10000 == 16, "Expected PostgreSQL 16.")

    provider_key = os.environ.get("OPENAI_API_KEY", "")
    provider_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com").rstrip("/")
    if args.live_provider:
        check(bool(provider_key), "A server-side provider key is required for the opt-in smoke test.")
        parsed = urlsplit(provider_url)
        check(parsed.scheme == "https" and parsed.hostname == "api.openai.com" and not parsed.username,
            "The synthetic live smoke test only permits the official HTTPS provider endpoint.")
    configure_qa_process(database_url)
    os.environ["MAX_CONCURRENT_TRANSCRIPTIONS"] = "2"
    if args.live_provider:
        os.environ["OPENAI_API_KEY"] = provider_key
        os.environ["OPENAI_BASE_URL"] = provider_url
    check("main" not in sys.modules, "Backend was imported before QA isolation.")
    sys.path.insert(0, "/app")
    backend = importlib.import_module("main")
    logging.disable(logging.CRITICAL)  # Avoid raw upstream error bodies/credentials in QA output.
    source_hash = hashlib.sha256(Path(backend.__file__).read_bytes()).hexdigest()
    check(source_hash == args.expected_backend_sha256, "Final image backend hash mismatch.")
    check(backend.is_postgres() and backend.DATABASE_URL == database_url, "Backend escaped QA database isolation.")
    from fastapi.testclient import TestClient
    from fastapi import HTTPException

    original_decoder, original_provider = backend.measure_audio_duration, backend.transcribe_audio
    measured = asyncio.run(original_decoder(audio))
    check(5 <= measured <= 8, "Synthetic AAC duration is unexpected.")
    try:
        asyncio.run(original_decoder(b"#EXTM3U\nhttps://example.invalid/private.mp3\n"))
    except HTTPException as exc:
        check(exc.status_code == 400, "Invalid/remote playlist produced an unexpected result.")
    else:
        raise VerificationFailure("Decoder accepted a remote playlist.")

    # Two near-limit PCM uploads exercise the 600-second boundary and peak
    # decode work without sending that long test data to the provider.
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b"\xe8\x03" * (600 * 16000))
    long_audio = buffer.getvalue()
    del buffer
    active_decoders = 0
    peak_decoders = 0
    decoded_durations = []
    async def counted_decoder(content):
        nonlocal active_decoders, peak_decoders
        active_decoders += 1
        peak_decoders = max(peak_decoders, active_decoders)
        try:
            seconds = await original_decoder(content)
            decoded_durations.append(seconds)
            return seconds
        finally:
            active_decoders -= 1
    backend.measure_audio_duration = counted_decoder
    held_providers, release = [], Event()
    both_entered = Event()
    async def held_provider(*args, **kwargs):
        held_providers.append(True)
        if len(held_providers) == 2:
            both_entered.set()
        deadline = time.monotonic() + 30
        while not release.is_set():
            check(time.monotonic() < deadline, "Bounded load test exceeded its deadline.")
            await asyncio.sleep(0.01)
        return {"text": "QA long audio", "usage": {"type": "tokens", "input_tokens": 1000, "output_tokens": 100}}
    backend.transcribe_audio = held_provider
    run_id = uuid.uuid4().hex
    def sign_in(client, suffix):
        response = client.post("/v1/auth/apple", json={"identity_token": f"dev:qa-media-{run_id}-{suffix}"})
        check(response.status_code == 200, "QA sign-in failed.")
        payload = response.json()
        return payload["user"]["id"], {"Authorization": f"Bearer {payload['token']}"}
    def fund(client, headers, amount=1_000_000):
        check(client.post("/v1/billing/dev-credit", headers=headers,
            json={"amount_usd_micros": amount}).status_code == 200, "QA credit funding failed.")
    def transcribe(client, headers, key, content, filename, duration="0"):
        return client.post("/v1/transcriptions", headers={**headers, "Idempotency-Key": key},
            data={"audio_seconds": duration}, files={"file": (filename, content, "audio/wav" if filename.endswith("wav") else "audio/m4a")})

    with TestClient(backend.app) as client, ThreadPoolExecutor(max_workers=2) as pool:
        user_id, headers = sign_in(client, "load")
        fund(client, headers)
        # Exercise the ASGI receive boundary with a missing Content-Length.
        # Lowering the limit is confined to this QA process, before load starts.
        import httpx
        original_limit = backend.MAX_AUDIO_BYTES
        chunks = []
        async def chunked_body():
            yield b'--qa\r\nContent-Disposition: form-data; name="file"; filename="chunked.m4a"\r\n\r\n'
            for _ in range(32):
                chunks.append(65536)
                yield b"x" * 65536
            yield b'\r\n--qa--\r\n'
        async def post_chunked():
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url="http://qa") as stream_client:
                return await stream_client.post("/v1/transcriptions", headers={**headers,
                    "Content-Type": "multipart/form-data; boundary=qa"}, content=chunked_body())
        try:
            backend.MAX_AUDIO_BYTES = 1024
            blocked_stream = asyncio.run(post_chunked())
        finally:
            backend.MAX_AUDIO_BYTES = original_limit
        check(blocked_stream.status_code == 413 and len(chunks) <= 2,
            "Oversized chunked upload was consumed before its limit was enforced.")
        print("PASS streaming upload bound " + json.dumps({"status": blocked_stream.status_code,
            "consumed_file_bytes": sum(chunks), "offered_file_bytes": 2097152}))
        for path in ("/v1/auth/apple", "/v1/billing/storekit/transactions", "/v1/billing/storekit/notifications"):
            json_chunks = []
            async def chunked_json():
                for _ in range(32):
                    json_chunks.append(65536)
                    yield b" " * 65536
            async def post_json():
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url="http://qa") as stream_client:
                    return await stream_client.post(path, headers={**headers, "Content-Type": "application/json"}, content=chunked_json())
            result = asyncio.run(post_json())
            check(result.status_code == 413 and sum(json_chunks) <= backend.request_body_limit(path) + 65536,
                "Oversized streamed JSON was consumed before its limit was enforced.")
        print("PASS streaming JSON bounds: Apple auth, StoreKit transaction, V2 notification")
        started = time.monotonic()
        first = pool.submit(transcribe, client, headers, uuid.uuid4().hex, long_audio, "load.wav")
        second = pool.submit(transcribe, client, headers, uuid.uuid4().hex, long_audio, "load.wav")
        try:
            check(both_entered.wait(40), "Two long recordings did not complete bounded decoding.")
            third = transcribe(client, headers, uuid.uuid4().hex, audio, "synthetic.m4a")
            check(third.status_code == 503 and third.headers.get("Retry-After") == "3", "Third active job was not rejected before decode.")
            check(len(decoded_durations) == 2 and peak_decoders == 2, "Expected exactly two concurrent decoders and no third decode.")
            check(all(599.95 <= value <= 600.05 for value in decoded_durations), "Actual long-file duration was not enforced.")
        finally:
            release.set()
        check(first.result(timeout=10).status_code == 200 and second.result(timeout=10).status_code == 200,
            "Two bounded jobs did not finish successfully.")
        load_seconds = round(time.monotonic() - started, 3)
        with backend.db() as conn:
            count = conn.execute("SELECT COUNT(*) AS n FROM credit_ledger WHERE user_id = %s AND kind = 'transcription'", (user_id,)).fetchone()["n"]
            holds = conn.execute("SELECT COUNT(*) AS n FROM credit_reservations WHERE user_id = %s", (user_id,)).fetchone()["n"]
            check(count == 2 and holds == 0, "Load-test debit/reservation count is incorrect.")
        print("PASS final-image media/load " + json.dumps({"aac_seconds": round(measured, 3),
            "long_upload_bytes_each": len(long_audio), "parallel_decoders": peak_decoders,
            "third_job_status": third.status_code, "two_job_elapsed_seconds": load_seconds}))

        backend.measure_audio_duration = original_decoder
        backend.transcribe_audio = original_provider
        del long_audio
        if args.live_provider:
            live_user_id, live_headers = sign_in(client, "live-provider")
            fund(client, live_headers)
            calls, provider_payloads = [], []
            async def observed_provider(*args, **kwargs):
                calls.append(True)
                payload = await original_provider(*args, **kwargs)
                provider_payloads.append(payload)
                return payload
            backend.transcribe_audio = observed_provider
            key = uuid.uuid4().hex
            started = time.monotonic()
            result = transcribe(client, live_headers, key, audio, "synthetic.m4a", "6.616")
            check(result.status_code == 200, "Live synthetic provider roundtrip failed.")
            payload = result.json()
            similarity = difflib.SequenceMatcher(None, normalized_text(EXPECTED_TEXT), normalized_text(payload["transcript"])).ratio()
            check(similarity >= 0.95, "Synthetic transcript did not match the expected phrase.")
            check(payload["charge"]["pricing_basis"] == "reported_usage", "Live provider did not return complete token usage.")
            elapsed = round(time.monotonic() - started, 3)
            fund(client, live_headers, 250_000)
            replay = transcribe(client, live_headers, key, audio, "synthetic.m4a", "6.616")
            check(replay.status_code == 200 and replay.json()["id"] == payload["id"], "Live result replay did not reuse the durable result.")
            check(replay.json()["charge"] == payload["charge"] and len(calls) == 1, "Live replay charged or called provider twice.")
            check(replay.json()["balance"]["balance_usd_micros"] == payload["balance"]["balance_usd_micros"] + 250_000,
                "Live replay did not report current balance.")
            with backend.db() as conn:
                row = conn.execute("SELECT COUNT(*) AS n, SUM(amount_usd_micros) AS amount FROM credit_ledger WHERE user_id = %s AND kind = 'transcription'", (live_user_id,)).fetchone()
                check(row["n"] == 1 and row["amount"] == -payload["charge"]["cost_usd_micros"], "Live provider ledger did not contain exactly one matching debit.")
            usage = provider_payloads[0].get("usage", {})
            print("PASS live synthetic provider/replay " + json.dumps({"model": payload["model"],
                "phrase_similarity": round(similarity, 4), "provider_calls": len(calls),
                "elapsed_seconds": elapsed, "input_tokens": usage.get("input_tokens"),
                "output_tokens": usage.get("output_tokens"), "charge_credits": payload["charge"]["cost_credit_units"],
                "ledger_debits": 1, "replay_current_balance": True}))
    events_path = Path("/sys/fs/cgroup/memory.events")
    if events_path.exists():
        events = dict(line.split() for line in events_path.read_text().splitlines())
        check(int(events.get("oom_kill", "0")) == 0, "Container had an OOM kill during validation.")
    print("PASS resource bounds " + json.dumps({"container_memory_max_bytes": cgroup_number("memory.max"),
        "container_memory_peak_bytes": cgroup_number("memory.peak"),
        "python_max_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        # Includes child process startup/fork; do not interpret as ffmpeg-only RSS.
        "child_process_max_rss_kib": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss}))
    print(f"PASS isolated QA database {args.database_name}; backend {source_hash}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database-name", required=True)
    parser.add_argument("--audio-path", required=True)
    parser.add_argument("--expected-audio-sha256", required=True)
    parser.add_argument("--expected-backend-sha256", required=True)
    parser.add_argument("--live-provider", action="store_true")
    args = parser.parse_args()
    try:
        verify(args)
        return 0
    except VerificationFailure as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
    except Exception as exc:
        print(f"FAIL: media verification raised {type(exc).__name__}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
