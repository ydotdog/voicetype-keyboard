"""Private owner console. Credentials never leave the server after being saved.

Only the official OpenAI endpoint is configurable in this release: changing the
data processor requires a corresponding disclosure/consent change in the app.
Configuration writes are atomic, encrypted, versioned and compare-and-swap.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import os
import secrets
import tempfile
import time
from collections import deque
from contextvars import ContextVar
from dataclasses import dataclass, field, replace
from pathlib import Path
from threading import Lock
from typing import Callable, Optional

import fcntl
import httpx
import jwt
from cryptography.fernet import Fernet, InvalidToken
from fastapi import HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from pydantic import BaseModel, Field, SecretStr


@dataclass(frozen=True)
class ProviderSettings:
    model: str
    account_id: str
    api_key: str = field(repr=False)
    base_url: str = "https://api.openai.com"
    revision: str = "environment"
    updated_at: str = ""

    def public(self) -> dict:
        return {"model": self.model, "account_id": self.account_id,
                "revision": self.revision, "updated_at": self.updated_at,
                "key_configured": bool(self.api_key), "provider": "OpenAI",
                "key_fingerprint": hashlib.sha256(self.api_key.encode()).hexdigest()[:10] if self.api_key else ""}


active_provider: ContextVar[Optional[ProviderSettings]] = ContextVar("active_provider", default=None)


class ProviderConfigStore:
    def __init__(self, path: str, encryption_key: str, defaults: Callable[[], ProviderSettings]):
        self.path = Path(path) if path else None
        self.cipher = Fernet(encryption_key.encode()) if encryption_key else None
        self.defaults = defaults
        self.lock = Lock()

    def _read(self) -> list[ProviderSettings]:
        if not self.path or not self.path.exists():
            return [self.defaults()]
        if not self.cipher:
            raise RuntimeError("Provider configuration encryption is unavailable.")
        try:
            data = json.loads(self.cipher.decrypt(self.path.read_bytes()))
            return [ProviderSettings(**row) for row in data["versions"]]
        except (InvalidToken, ValueError, KeyError, TypeError):
            # Never fall back silently to an old environment key on corruption.
            raise RuntimeError("Provider configuration could not be read.") from None

    def current(self) -> ProviderSettings:
        with self.lock:
            return self._read()[0]

    def history(self) -> list[dict]:
        with self.lock:
            return [row.public() for row in self._read()]

    def version(self, revision: str) -> ProviderSettings:
        with self.lock:
            for row in self._read():
                if row.revision == revision:
                    return row
        raise HTTPException(404, "That configuration is no longer retained.")

    def save(self, candidate: ProviderSettings, expected_revision: str) -> ProviderSettings:
        if not self.path or not self.cipher:
            raise HTTPException(503, "Provider management is not configured.")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.lock, open(str(self.path) + ".lock", "a") as lock_file:
            fcntl.flock(lock_file, fcntl.LOCK_EX)
            rows = self._read()
            if rows[0].revision != expected_revision:
                raise HTTPException(409, "Configuration changed. Reload before saving.")
            from datetime import datetime, timezone
            saved = replace(candidate, revision=secrets.token_hex(12), updated_at=datetime.now(timezone.utc).isoformat())
            versions = [saved] + rows[:9]
            content = self.cipher.encrypt(json.dumps({"versions": [vars(row) for row in versions]}).encode())
            fd, name = tempfile.mkstemp(prefix=".provider-", dir=self.path.parent)
            try:
                with os.fdopen(fd, "wb") as stream:
                    os.fchmod(stream.fileno(), 0o600)
                    stream.write(content); stream.flush(); os.fsync(stream.fileno())
                os.replace(name, self.path)
                parent_fd = os.open(self.path.parent, os.O_RDONLY)
                try: os.fsync(parent_fd)
                finally: os.close(parent_fd)
            finally:
                if os.path.exists(name): os.unlink(name)
            return saved


def password_hash(password: str, salt: Optional[str] = None) -> str:
    salt = salt or secrets.token_hex(16)
    value = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 600_000)
    return f"pbkdf2_sha256${salt}${base64.b64encode(value).decode()}"


def password_matches(password: str, encoded: str) -> bool:
    try:
        scheme, salt, _ = encoded.split("$")
        return scheme == "pbkdf2_sha256" and hmac.compare_digest(password_hash(password, salt), encoded)
    except (ValueError, TypeError):
        return False


class LoginInput(BaseModel):
    password: SecretStr


class ConfigInput(BaseModel):
    model: str = Field(min_length=1, max_length=128)
    account_id: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9._-]+$")
    api_key: SecretStr = SecretStr("")
    expected_revision: str = Field(max_length=64)
    restore_revision: Optional[str] = Field(default=None, max_length=64)
    test_token: str = Field(default="", max_length=2048)


def install_admin(app, store: ProviderConfigStore, models: dict, logger) -> None:
    session_secret = os.getenv("ADMIN_SESSION_SECRET", "")
    encoded_password = os.getenv("ADMIN_PASSWORD_HASH", "")
    origin = os.getenv("ADMIN_ORIGIN", "https://voicetype.y.dog").rstrip("/")
    secure = not origin.startswith("http://127.0.0.1:")
    enabled = len(session_secret) >= 32 and bool(encoded_password) and store.path is not None and store.cipher is not None
    cookie_name = "__Secure-voicetype-admin" if secure else "voicetype-admin-local"
    attempts: dict[str, deque] = {}
    limit_lock = Lock()
    sessions: dict[str, int] = {}
    events = deque(maxlen=30)
    event_lock = Lock()

    def record(kind: str, **values):
        with event_lock:
            events.appendleft({"time": int(time.time()), "kind": kind, **values})
        logger.info(kind, extra=values)

    class ProviderEvents(logging.Handler):
        voicetype_owner_events = True
        def emit(self, item):
            if item.getMessage() == "transcription_provider_error":
                with event_lock:
                    events.appendleft({"time": int(time.time()), "kind": "transcription_provider_error",
                                       "status": getattr(item, "status_code", "unavailable")})
    for handler in list(logger.handlers):
        if getattr(handler, "voicetype_owner_events", False): logger.removeHandler(handler)
    logger.addHandler(ProviderEvents())

    def available():
        if not enabled: raise HTTPException(404, "Not found.")

    def same_origin(request: Request):
        available()
        if request.headers.get("origin") != origin or request.headers.get("sec-fetch-site", "same-origin") not in {"same-origin", "none"}:
            raise HTTPException(403, "Reload this page before trying again.")

    def authenticate(request: Request) -> dict:
        available()
        try:
            decoded = jwt.decode(request.cookies.get(cookie_name, ""), session_secret, algorithms=["HS256"],
                              audience="voicetype-admin", options={"require": ["exp", "aud", "sub", "sid"]})
            with limit_lock:
                if sessions.get(decoded["sid"], 0) <= time.time(): raise jwt.InvalidTokenError()
            return decoded
        except jwt.PyJWTError:
            raise HTTPException(401, "Please sign in to the owner console.") from None

    def rate_limit(key: str, count: int, seconds: int):
        now = time.monotonic()
        with limit_lock:
            for old in list(attempts):
                if not attempts[old] or attempts[old][-1] < now - 3600: attempts.pop(old)
            if key not in attempts and len(attempts) >= 2000:
                raise HTTPException(429, "Too many attempts. Try again later.")
            q = attempts.setdefault(key, deque())
            while q and q[0] <= now - seconds: q.popleft()
            if len(q) >= count: raise HTTPException(429, "Too many attempts. Try again later.")
            q.append(now)

    def candidate(body: ConfigInput) -> ProviderSettings:
        current = store.current()
        if current.revision != body.expected_revision:
            raise HTTPException(409, "Configuration changed. Reload before testing.")
        if body.restore_revision:
            value = store.version(body.restore_revision)
        else:
            key = body.api_key.get_secret_value().strip() or current.api_key
            if not key or len(key) > 512 or any(ch.isspace() for ch in key):
                raise HTTPException(400, "Enter a valid API key.")
            value = ProviderSettings(model=body.model, account_id=body.account_id, api_key=key)
        if value.model not in models or value.base_url != "https://api.openai.com":
            raise HTTPException(400, "Select a supported OpenAI transcription model.")
        return value

    def digest(value: ProviderSettings) -> str:
        return hmac.new(session_secret.encode(), json.dumps([value.model, value.account_id, value.api_key, value.base_url]).encode(), hashlib.sha256).hexdigest()

    class AdminHeaders:
        def __init__(self, app): self.app = app
        async def __call__(self, scope, receive, send):
            if scope["type"] != "http" or not scope.get("path", "").startswith("/admin"):
                await self.app(scope, receive, send)
                return
            async def secure_send(message):
                if message["type"] == "http.response.start":
                    headers = dict(message.get("headers", []))
                    headers.update({b"cache-control": b"no-store", b"referrer-policy": b"no-referrer",
                        b"x-content-type-options": b"nosniff", b"x-frame-options": b"DENY",
                        b"content-security-policy": b"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"})
                    message = {**message, "headers": list(headers.items())}
                await send(message)
            await self.app(scope, receive, secure_send)
    app.add_middleware(AdminHeaders)

    @app.get("/admin", response_class=HTMLResponse, include_in_schema=False)
    def page():
        available()
        return HTMLResponse((Path(__file__).parent / "admin/index.html").read_text())

    @app.get("/admin/assets/{name}", include_in_schema=False)
    def asset(name: str):
        available()
        types = {"admin.js": "application/javascript", "admin.css": "text/css"}
        if name not in types: raise HTTPException(404, "Not found.")
        return Response((Path(__file__).parent / "admin" / name).read_text(), media_type=types[name])

    @app.post("/admin/api/login", include_in_schema=False)
    def login(body: LoginInput, request: Request):
        same_origin(request)
        # Global bound is intentional: never trust a spoofable forwarding header.
        rate_limit("login", 12, 900)
        password = body.password.get_secret_value()
        if len(password) > 256 or not password_matches(password, encoded_password):
            raise HTTPException(401, "Incorrect password.")
        sid = secrets.token_hex(16)
        with limit_lock:
            for old in list(sessions):
                if sessions[old] <= time.time(): sessions.pop(old)
            sessions[sid] = int(time.time()) + 3600
        token = jwt.encode({"sub": "owner", "sid": sid, "aud": "voicetype-admin", "iat": int(time.time()), "exp": int(time.time()) + 3600}, session_secret, algorithm="HS256")
        response = JSONResponse({"ok": True})
        response.set_cookie(cookie_name, token, max_age=3600, httponly=True, secure=secure, samesite="strict", path="/admin")
        record("admin_signed_in")
        return response

    @app.post("/admin/api/logout", include_in_schema=False)
    def logout(request: Request):
        same_origin(request)
        session = authenticate(request)
        with limit_lock: sessions.pop(session["sid"], None)
        response = JSONResponse({"ok": True})
        response.delete_cookie(cookie_name, path="/admin", secure=secure, httponly=True, samesite="strict")
        return response

    @app.get("/admin/api/state", include_in_schema=False)
    def state(request: Request):
        authenticate(request)
        with event_lock: recent = list(events)
        return {"current": store.current().public(), "history": store.history(),
                "models": [{"id": k, "pricing": v} for k, v in models.items()], "events": recent}

    @app.post("/admin/api/test", include_in_schema=False)
    async def test(body: ConfigInput, request: Request):
        same_origin(request); session = authenticate(request)
        rate_limit("test", 6, 60)
        value = candidate(body)
        # This contains only bundled synthetic speech, never customer recordings.
        clip = (Path(__file__).parent / "admin/test-phrase.wav").read_bytes()
        data = {"model": value.model, "response_format": "json", "language": "en"}
        if value.model == "whisper-1": data["response_format"] = "verbose_json"
        if value.model == "gpt-4o-transcribe-diarize": data["chunking_strategy"] = "auto"
        started = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=30, follow_redirects=False, trust_env=False) as client:
                result = await client.post("https://api.openai.com/v1/audio/transcriptions",
                    headers={"Authorization": f"Bearer {value.api_key}"}, data=data,
                    files={"file": ("test.wav", clip, "audio/wav")})
            if result.status_code != 200:
                record("provider_test_failed", status=result.status_code)
                detail = {401: "API key was rejected.", 403: "This key cannot access the model.",
                          429: "Provider quota or rate limit reached. Check the OpenAI account."}.get(result.status_code, "Provider test failed. Existing settings are unchanged.")
                raise HTTPException(502, detail)
            transcript = result.json().get("text")
            if not isinstance(transcript, str) or not transcript.strip(): raise ValueError()
        except (httpx.HTTPError, ValueError, AttributeError):
            record("provider_test_failed", status="unavailable")
            raise HTTPException(502, "No usable transcription was returned. Existing settings are unchanged.") from None
        elapsed = round((time.monotonic() - started) * 1000)
        proof = jwt.encode({"aud": "voicetype-provider-test", "sid": session["sid"], "digest": digest(value),
                            "revision": body.expected_revision, "exp": int(time.time()) + 600}, session_secret, algorithm="HS256")
        record("provider_test_passed", model=value.model, latency_ms=elapsed)
        return {"ok": True, "transcript": transcript[:500], "latency_ms": elapsed, "test_token": proof}

    @app.post("/admin/api/config", include_in_schema=False)
    def save(body: ConfigInput, request: Request):
        same_origin(request); session = authenticate(request)
        value = candidate(body)
        try:
            proof = jwt.decode(body.test_token, session_secret, algorithms=["HS256"], audience="voicetype-provider-test",
                               options={"require": ["exp", "sid", "digest", "revision"]})
            valid = proof["sid"] == session["sid"] and proof["revision"] == body.expected_revision and hmac.compare_digest(proof["digest"], digest(value))
        except jwt.PyJWTError: valid = False
        if not valid: raise HTTPException(400, "Test these exact settings before saving.")
        saved = store.save(value, body.expected_revision)
        record("provider_config_saved", model=saved.model, revision=saved.revision)
        return {"ok": True, "current": saved.public()}
