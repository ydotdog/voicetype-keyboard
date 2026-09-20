"""Streaming upload limits must precede multipart spooling, even without length."""

import asyncio

import httpx
import pytest
from fastapi.testclient import TestClient
import starlette.formparsers

from test_billing import auth, load_main
from test_reliability import fund


PREFIX = b'--qa\r\nContent-Disposition: form-data; name="file"; filename="clip.m4a"\r\nContent-Type: audio/m4a\r\n\r\n'
SUFFIX = b'\r\n--qa--\r\n'


def streamed_post(main, headers, body):
    async def run():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://qa") as client:
            return await client.post("/v1/transcriptions", headers={"Content-Type": "multipart/form-data; boundary=qa", **headers}, content=body)
    return asyncio.run(run())


@pytest.mark.parametrize("declared_length", [None, "1"])
def test_streamed_oversized_upload_stops_early_and_closes_partial_file(tmp_path, monkeypatch, declared_length):
    main = load_main(tmp_path, monkeypatch)
    main.MAX_AUDIO_BYTES = 1024
    sent = []
    spooled = []
    original = starlette.formparsers.SpooledTemporaryFile
    def tracked_file(*args, **kwargs):
        file = original(*args, **kwargs)
        spooled.append(file)
        return file
    monkeypatch.setattr(starlette.formparsers, "SpooledTemporaryFile", tracked_file)
    async def body():
        yield PREFIX
        for _ in range(32):
            sent.append(65536)
            yield b"x" * 65536
        yield SUFFIX
    async def decoder(audio):
        pytest.fail("An oversized stream must never reach audio validation")
    monkeypatch.setattr(main, "measure_audio_duration", decoder)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        headers = dict(user["headers"])
        if declared_length is not None:
            headers["Content-Length"] = declared_length
        response = streamed_post(main, headers, body())
        assert response.status_code == 413, response.text
        # At most one transport chunk beyond the bounded envelope is received;
        # the rest of the 2 MiB stream is never consumed or written to disk.
        assert sum(sent) <= main.MAX_AUDIO_BYTES + 65536 + 65536
        assert len(sent) < 32
        assert spooled and all(file.closed for file in spooled)
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM credit_reservations").fetchone()[0] == 0


def test_valid_chunked_multipart_reaches_provider_once(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.MAX_AUDIO_BYTES = 1024
    calls = []
    async def provider(audio, *args, **kwargs):
        calls.append(audio)
        return {"text": "valid stream", "usage": {"input_tokens": 50, "output_tokens": 5}}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    async def body():
        content = PREFIX + b"valid fake audio" + SUFFIX
        for offset in range(0, len(content), 7):
            yield content[offset:offset + 7]
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = streamed_post(main, user["headers"], body())
    assert response.status_code == 200, response.text
    assert response.json()["transcript"] == "valid stream"
    assert calls == [b"valid fake audio"]


def test_limit_applies_to_multipart_fields_before_a_file(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.MAX_AUDIO_BYTES = 1024
    sent = []
    async def body():
        yield b'--qa\r\nContent-Disposition: form-data; name="unknown"\r\n\r\n'
        for _ in range(32):
            sent.append(65536)
            yield b"x" * 65536
        yield SUFFIX
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        response = streamed_post(main, user["headers"], body())
    assert response.status_code == 413
    assert len(sent) < 32


@pytest.mark.parametrize("path,field", [
    ("/v1/auth/apple", "identity_token"),
    ("/v1/billing/storekit/transactions", "signed_transaction"),
    ("/v1/billing/storekit/notifications", "signedPayload"),
])
def test_streamed_json_is_bounded_before_json_parsing(tmp_path, monkeypatch, path, field):
    main = load_main(tmp_path, monkeypatch)
    sent = []
    async def body():
        yield ('{"' + field + '":"').encode()
        for _ in range(128):
            sent.append(8192)
            yield b"x" * 8192
        yield b'"}'
    async def run():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://qa") as client:
            return await client.post(path, headers={"Content-Type": "application/json"}, content=body())
    with TestClient(main.app):
        response = asyncio.run(run())
    assert response.status_code == 413, response.text
    assert sum(sent) <= main.request_body_limit(path) + 8192
    assert len(sent) < 128


def test_largest_valid_webhook_field_fits_json_body_limit(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    payload = "x" * 131072
    verified = []
    def verify(signed):
        verified.append(signed)
        return {"notification_type": "TEST"}
    monkeypatch.setattr(main, "verify_storekit_notification", verify)
    with TestClient(main.app) as client:
        response = client.post("/v1/billing/storekit/notifications", json={"signedPayload": payload})
    assert response.status_code == 200, response.text
    assert verified == [payload]
