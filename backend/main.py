from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import logging
import math
import os
import re
import sqlite3
import time
import uuid
from collections import deque
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime, timedelta, timezone
from typing import Annotated, Any, Optional

import httpx
import jwt
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse
from jwt import PyJWKClient
from pydantic import BaseModel, Field

try:
    import psycopg
    from psycopg.rows import dict_row
    from psycopg_pool import ConnectionPool
except ImportError:  # Local lightweight development can still use SQLite.
    psycopg = None
    dict_row = None
    ConnectionPool = None

try:
    from appstoreserverlibrary.models.Environment import Environment
    from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier
except ImportError:
    Environment = None
    SignedDataVerifier = None


OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "https://api.openai.com").rstrip("/")
OPENAI_TRANSCRIBE_MODEL = os.getenv("OPENAI_TRANSCRIBE_MODEL", "gpt-4o-mini-transcribe")
OPENAI_PROVIDER_ACCOUNT_ID = os.getenv("OPENAI_PROVIDER_ACCOUNT_ID", "openai-primary")
SUPPORT_EMAIL = os.getenv("SUPPORT_EMAIL", "kq@apeonwheels.com")

DATABASE_URL = os.getenv("DATABASE_URL", "")
DATABASE_PATH = os.getenv("DATABASE_PATH", "./voicetype.sqlite3")

JWT_SECRET = os.getenv("JWT_SECRET", "")
JWT_ISSUER = os.getenv("JWT_ISSUER", "voicetype")
JWT_TTL_DAYS = int(os.getenv("JWT_TTL_DAYS", "365"))

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_CLIENT_ID = os.getenv("APPLE_CLIENT_ID", "com.kyleqi.voicetype")
APPLE_BUNDLE_ID = os.getenv("APPLE_BUNDLE_ID", APPLE_CLIENT_ID)
APPLE_APP_APPLE_ID = os.getenv("APPLE_APP_APPLE_ID", "")
APPLE_AUTH_DEV_BYPASS = os.getenv("APPLE_AUTH_DEV_BYPASS", "").lower() in {"1", "true", "yes"}

# Sign in with Apple server-to-server credentials. Used to exchange the
# authorization code for a refresh token at sign-in and to revoke that token
# when the user deletes their account (App Store Guideline 5.1.1(v)).
APPLE_TOKEN_URL = os.getenv("APPLE_TOKEN_URL", "https://appleid.apple.com/auth/token")
APPLE_REVOKE_URL = os.getenv("APPLE_REVOKE_URL", "https://appleid.apple.com/auth/revoke")
APPLE_SIGNIN_TEAM_ID = os.getenv("APPLE_SIGNIN_TEAM_ID", "")
APPLE_SIGNIN_KEY_ID = os.getenv("APPLE_SIGNIN_KEY_ID", "")
APPLE_SIGNIN_PRIVATE_KEY = os.getenv("APPLE_SIGNIN_PRIVATE_KEY", "")
APPLE_SIGNIN_PRIVATE_KEY_PATH = os.getenv("APPLE_SIGNIN_PRIVATE_KEY_PATH", "")
APPLE_SIGNIN_PRIVATE_KEY_B64 = os.getenv("APPLE_SIGNIN_PRIVATE_KEY_B64", "")

STOREKIT_VERIFICATION_MODE = os.getenv("STOREKIT_VERIFICATION_MODE", "strict").lower()
ALLOW_UNVERIFIED_STOREKIT_JWS = os.getenv("ALLOW_UNVERIFIED_STOREKIT_JWS", "").lower() in {"1", "true", "yes"}
REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN = os.getenv("REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN", "true").lower() in {"1", "true", "yes"}
ALLOW_DEV_CREDIT = os.getenv("ALLOW_DEV_CREDIT", "").lower() in {"1", "true", "yes"}
DEV_CREDIT_SHARED_SECRET = os.getenv("DEV_CREDIT_SHARED_SECRET", "")
APPLE_STOREKIT_ENVIRONMENT = os.getenv("APPLE_STOREKIT_ENVIRONMENT", "PRODUCTION").upper()
APPLE_ROOT_CERTIFICATE_PATHS = os.getenv("APPLE_ROOT_CERTIFICATE_PATHS", "")
APPLE_ROOT_CERTIFICATE_PEMS_B64 = os.getenv("APPLE_ROOT_CERTIFICATE_PEMS_B64", "")

FALLBACK_AUDIO_TOKENS_PER_SECOND = float(os.getenv("FALLBACK_AUDIO_TOKENS_PER_SECOND", "50"))
APPLE_COMMISSION_BPS = int(os.getenv("APPLE_COMMISSION_BPS", "3000"))
TARGET_PROFIT_MARGIN_BPS = int(os.getenv("TARGET_PROFIT_MARGIN_BPS", "2000"))
MAX_AUDIO_BYTES = int(os.getenv("MAX_AUDIO_BYTES", str(24 * 1024 * 1024)))

USD_MICROS = 1_000_000
CREDIT_UNITS_PER_USD = 1_000_000
DEV_CREDIT_MAX_USD_MICROS = int(os.getenv("DEV_CREDIT_MAX_USD_MICROS", str(20 * USD_MICROS)))

# One-time welcome credit granted the first time a user signs in. Gives App
# Review (and real first-run users) something to transcribe without a purchase.
SIGNUP_GRANT_ENABLED = os.getenv("SIGNUP_GRANT_ENABLED", "true").lower() in {"1", "true", "yes"}
SIGNUP_GRANT_USD_MICROS = int(os.getenv("SIGNUP_GRANT_USD_MICROS", "100000"))


def default_cost_markup_bps() -> int:
    if APPLE_COMMISSION_BPS >= 10_000:
        raise RuntimeError("APPLE_COMMISSION_BPS must be less than 10000.")
    gross_multiplier_bps = math.ceil((10_000 + TARGET_PROFIT_MARGIN_BPS) * 10_000 / (10_000 - APPLE_COMMISSION_BPS))
    return max(0, gross_multiplier_bps - 10_000)


DEFAULT_COST_MARKUP_BPS = default_cost_markup_bps()
COST_MARKUP_BPS = int(os.getenv("COST_MARKUP_BPS", str(DEFAULT_COST_MARKUP_BPS)))
MIN_TRANSCRIPTION_RESERVATION_USD_MICROS = int(os.getenv("MIN_TRANSCRIPTION_RESERVATION_USD_MICROS", "20000"))
AUDIO_BYTES_PER_SECOND_FLOOR = max(1, int(os.getenv("AUDIO_BYTES_PER_SECOND_FLOOR", "2500")))
CREDIT_RESERVATION_TTL_SECONDS = int(os.getenv("CREDIT_RESERVATION_TTL_SECONDS", "1800"))

RATE_LIMIT_ENABLED = os.getenv("RATE_LIMIT_ENABLED", "true").lower() in {"1", "true", "yes"}
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "60"))
AUTH_RATE_LIMIT_PER_WINDOW = int(os.getenv("AUTH_RATE_LIMIT_PER_WINDOW", "20"))
TRANSCRIPTION_RATE_LIMIT_PER_WINDOW = int(os.getenv("TRANSCRIPTION_RATE_LIMIT_PER_WINDOW", "30"))
BILLING_RATE_LIMIT_PER_WINDOW = int(os.getenv("BILLING_RATE_LIMIT_PER_WINDOW", "60"))
RATE_LIMIT_MAX_KEYS = int(os.getenv("RATE_LIMIT_MAX_KEYS", "20000"))
RATE_LIMIT_CLEANUP_INTERVAL_SECONDS = int(os.getenv("RATE_LIMIT_CLEANUP_INTERVAL_SECONDS", "60"))
TRUSTED_PROXY_CIDRS = os.getenv("TRUSTED_PROXY_CIDRS", "127.0.0.1/32,::1/128")

_STANDARD_LOG_RECORD_FIELDS = set(logging.makeLogRecord({}).__dict__.keys())


class JsonExtraFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key not in _STANDARD_LOG_RECORD_FIELDS and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str, separators=(",", ":"))


def configure_logging() -> None:
    level = os.getenv("LOG_LEVEL", "INFO").upper()
    log_format = os.getenv("LOG_FORMAT", "json").lower()
    handler = logging.StreamHandler()
    if log_format == "json":
        handler.setFormatter(JsonExtraFormatter())
    else:
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    root_logger = logging.getLogger()
    root_logger.handlers = [handler]
    root_logger.setLevel(level)


configure_logging()
logger = logging.getLogger("voicetype.api")
_rate_limit_hits: dict[str, deque[float]] = {}
_rate_limit_last_cleanup = 0.0
_IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_trusted_proxy_networks = [
    ipaddress.ip_network(value.strip())
    for value in TRUSTED_PROXY_CIDRS.split(",")
    if value.strip()
]


DEFAULT_PRODUCTS = [
    {
        "id": "com.kyleqi.voicetype.credits.small",
        "display_name": "990,000 credits",
        "credit_usd_micros": 990_000,
        "subtitle": "$0.99 pack",
    },
    {
        "id": "com.kyleqi.voicetype.credits.medium",
        "display_name": "4,990,000 credits",
        "credit_usd_micros": 4_990_000,
        "subtitle": "$4.99 pack",
    },
    {
        "id": "com.kyleqi.voicetype.credits.large",
        "display_name": "19,990,000 credits",
        "credit_usd_micros": 19_990_000,
        "subtitle": "$19.99 pack",
    },
]


MODEL_PRICING = {
    "whisper-1": {"basis": "audio_minutes", "per_minute_usd_micros": 6_000},
    "gpt-4o-mini-transcribe": {
        "basis": "tokens",
        "input_per_million_usd_micros": 1_250_000,
        "output_per_million_usd_micros": 5_000_000,
    },
    "gpt-4o-transcribe": {
        "basis": "tokens",
        "input_per_million_usd_micros": 2_500_000,
        "output_per_million_usd_micros": 10_000_000,
    },
    "gpt-4o-transcribe-diarize": {
        "basis": "tokens",
        "input_per_million_usd_micros": 2_500_000,
        "output_per_million_usd_micros": 10_000_000,
    },
}


@asynccontextmanager
async def lifespan(_: FastAPI) -> Any:
    on_startup()
    try:
        yield
    finally:
        on_shutdown()


app = FastAPI(title="VoiceType API", version="0.2.0", lifespan=lifespan)
apple_jwks = PyJWKClient(APPLE_JWKS_URL)
pg_pool: Optional[Any] = None


def privacy_policy_html() -> str:
    support_email = SUPPORT_EMAIL
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>VoiceType Privacy Policy</title>
  <style>
    :root {{
      color-scheme: light dark;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.55;
      color: #1f1b16;
      background: #f4efe5;
    }}
    body {{
      margin: 0;
      padding: 40px 20px;
    }}
    main {{
      max-width: 760px;
      margin: 0 auto;
    }}
    h1, h2 {{
      line-height: 1.2;
    }}
    table {{
      border-collapse: collapse;
      width: 100%;
      margin: 16px 0;
      font-size: 0.95rem;
    }}
    th, td {{
      border: 1px solid rgba(80, 70, 54, 0.25);
      padding: 10px;
      text-align: left;
      vertical-align: top;
    }}
    a {{
      color: #8b5200;
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        color: #f1eadb;
        background: #16120d;
      }}
      th, td {{
        border-color: rgba(241, 234, 219, 0.22);
      }}
      a {{
        color: #f0bf61;
      }}
    }}
  </style>
</head>
<body>
<main>
  <h1>VoiceType Privacy Policy</h1>
  <p><em>Last updated: 2026-06-13</em></p>

  <p>VoiceType turns your speech into text. This policy explains what we collect,
  why, who processes it, and how you can delete it.</p>

  <h2>Summary</h2>
  <ul>
    <li>We do not track you across other apps or websites.</li>
    <li>We do not sell your data or share it with data brokers or advertisers.</li>
    <li>You can delete your account and all associated data from inside the app at any time.</li>
  </ul>

  <h2>What we collect and why</h2>
  <table>
    <thead>
      <tr><th>Data</th><th>Why</th><th>Linked to you</th><th>Kept</th></tr>
    </thead>
    <tbody>
      <tr><td>Apple account identifier and email</td><td>Create and sign in to your account</td><td>Yes</td><td>Until you delete your account</td></tr>
      <tr><td>Name, only if shared at sign-in</td><td>Personalize your account</td><td>Yes</td><td>Until you delete your account</td></tr>
      <tr><td>Audio you record</td><td>Sent to our transcription provider to produce text</td><td>Yes, in transit</td><td>Streamed for processing; not retained as audio files by default</td></tr>
      <tr><td>Transcribed text</td><td>Returned to you and shown in your history</td><td>Yes</td><td>Until you delete your account</td></tr>
      <tr><td>Purchase records</td><td>Verify credit purchases and prevent duplicate grants</td><td>Yes</td><td>Until you delete your account</td></tr>
    </tbody>
  </table>

  <p>We never ask for your Apple password. Sign in with Apple lets you hide your
  email with Apple's private relay; we support that.</p>

  <h2>How transcription works</h2>
  <p>When you record, the app keeps an audio session active so the VoiceType
  keyboard can mark the speech to transcribe. Audio is sent over an encrypted
  connection to our backend, which forwards it to OpenAI solely to generate the
  transcript. Audio is processed transiently and is not stored as files by
  default. The resulting transcript is stored in your account so you can reuse it
  and is cached in a shared container on your device so the keyboard can insert
  it into the current text field.</p>

  <h2>Third parties</h2>
  <ul>
    <li>Apple: Sign in with Apple and App Store payments.</li>
    <li>OpenAI: speech-to-text processing of audio you submit.</li>
  </ul>
  <p>We do not integrate advertising or analytics SDKs.</p>

  <h2>Microphone and Full Access</h2>
  <ul>
    <li>Microphone: used only to capture the speech you choose to transcribe.</li>
    <li>Keyboard Full Access: used so the VoiceType keyboard can read the latest
    transcript and recording state from the app's shared container. The keyboard
    does not transmit your keystrokes to us.</li>
  </ul>

  <h2>Data retention and deletion</h2>
  <p>Your account data is kept until you delete it. To delete everything, open
  VoiceType, go to Settings, choose Delete account, and confirm. This permanently
  removes your user record, remaining credit, transcription history, and stored
  purchase records, and revokes the app's Sign in with Apple token grant.
  Deletion cannot be undone. Purchases already consumed are not refundable
  through deletion; refunds are handled by Apple.</p>

  <h2>Children</h2>
  <p>VoiceType is not directed to children under 13 and does not knowingly collect
  their data.</p>

  <h2>Changes</h2>
  <p>We may update this policy. Material changes will be reflected by the Last
  updated date above.</p>

  <h2>Contact</h2>
  <p>Questions or requests: <a href="mailto:{support_email}">{support_email}</a></p>
</main>
</body>
</html>"""


@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next: Any) -> Any:
    rate_limit = rate_limit_for_path(request.url.path)
    if RATE_LIMIT_ENABLED and rate_limit:
        allowed, retry_after = check_rate_limit(request, limit=rate_limit, window_seconds=RATE_LIMIT_WINDOW_SECONDS)
        if not allowed:
            logger.warning("rate_limit_exceeded", extra={"path": request.url.path, "retry_after": retry_after})
            return JSONResponse(
                status_code=429,
                content={"detail": "Too many requests. Try again shortly."},
                headers={"Retry-After": str(retry_after)},
            )

    started = time.monotonic()
    try:
        response = await call_next(request)
    except Exception:
        logger.exception("request_failed", extra={"path": request.url.path})
        raise

    if response.status_code >= 400 and request.url.path.startswith("/v1/"):
        logger.warning(
            "request_error_response",
            extra={
                "path": request.url.path,
                "status_code": response.status_code,
                "duration_ms": round((time.monotonic() - started) * 1000, 2),
            },
        )
    return response


class AppleAuthRequest(BaseModel):
    identity_token: str = Field(min_length=4)
    authorization_code: Optional[str] = None
    email: Optional[str] = None
    full_name: Optional[str] = None


class AuthUser(BaseModel):
    id: str
    email: Optional[str] = None


class BalancePayload(BaseModel):
    balance_usd_micros: int
    balance_credit_units: int
    formatted: str


class AuthResponse(BaseModel):
    token: str
    user: AuthUser
    balance: BalancePayload


class CreditProduct(BaseModel):
    id: str
    display_name: str
    credit_usd_micros: int
    credit_units: int
    subtitle: str


class StoreKitTransactionRequest(BaseModel):
    signed_transaction: str = Field(min_length=16)


class PurchaseCreditResponse(BaseModel):
    balance: BalancePayload
    granted_usd_micros: int
    granted_credit_units: int
    already_processed: bool


class DevCreditRequest(BaseModel):
    amount_usd_micros: int = Field(gt=0, le=100 * USD_MICROS)


class ChargePayload(BaseModel):
    cost_usd_micros: int
    cost_credit_units: int
    formatted: str
    pricing_basis: str


class TranscriptionResponse(BaseModel):
    id: str
    transcript: str
    model: str
    charge: ChargePayload
    balance: BalancePayload


class LedgerEntry(BaseModel):
    id: str
    amount_usd_micros: int
    kind: str
    description: str
    created_at: str


class LedgerResponse(BaseModel):
    balance: BalancePayload
    items: list[LedgerEntry]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def credit_units_from_usd_micros(micros: int) -> int:
    return math.ceil(micros * CREDIT_UNITS_PER_USD / USD_MICROS)


def format_credits(micros: int) -> str:
    return f"{credit_units_from_usd_micros(micros):,} credits"


def is_postgres() -> bool:
    return DATABASE_URL.startswith(("postgres://", "postgresql://"))


def product_catalog() -> list[dict[str, Any]]:
    raw = os.getenv("CREDIT_PRODUCTS_JSON", "")
    if raw:
        parsed = json.loads(raw)
        if not isinstance(parsed, list):
            raise RuntimeError("CREDIT_PRODUCTS_JSON must be a JSON list.")
        return parsed
    return DEFAULT_PRODUCTS


def product_payload(product: dict[str, Any]) -> dict[str, Any]:
    credit = int(product["credit_usd_micros"])
    return {**product, "credit_units": credit_units_from_usd_micros(credit)}


def product_by_id(product_id: str) -> dict[str, Any]:
    for product in product_catalog():
        if product["id"] == product_id:
            return product
    raise HTTPException(status_code=400, detail=f"Unknown product id: {product_id}")


def sql(query: str) -> str:
    return query.replace("?", "%s") if is_postgres() else query


def quote_identifier(identifier: str) -> str:
    if not _IDENTIFIER_RE.match(identifier):
        raise RuntimeError(f"Unsafe SQL identifier: {identifier}")
    return f'"{identifier}"'


def row_to_dict(row: Any) -> dict[str, Any]:
    return dict(row) if row is not None else {}


def execute(conn: Any, query: str, params: tuple[Any, ...] = ()) -> Any:
    return conn.execute(sql(query), params)


def is_unique_violation(exc: BaseException) -> bool:
    if isinstance(exc, sqlite3.IntegrityError):
        return "UNIQUE constraint failed" in str(exc)
    if psycopg is not None and isinstance(exc, psycopg.errors.UniqueViolation):
        return True
    return False


def rate_limit_for_path(path: str) -> Optional[int]:
    if path in ("/v1/auth/apple", "/v1/account"):
        return AUTH_RATE_LIMIT_PER_WINDOW
    if path == "/v1/transcriptions":
        return TRANSCRIPTION_RATE_LIMIT_PER_WINDOW
    if path.startswith("/v1/billing/"):
        return BILLING_RATE_LIMIT_PER_WINDOW
    return None


def rate_limit_identity(request: Request) -> str:
    authorization = request.headers.get("authorization", "")
    if authorization.startswith("Bearer "):
        digest = hashlib.sha256(authorization.encode("utf-8")).hexdigest()[:20]
        return f"token:{digest}"
    return f"ip:{client_ip_for_rate_limit(request)}"


def client_ip_for_rate_limit(request: Request) -> str:
    remote_host = request.client.host if request.client else "unknown"
    if not is_trusted_proxy(remote_host):
        return remote_host

    real_ip = normalized_ip(request.headers.get("x-real-ip", ""))
    if real_ip:
        return real_ip

    forwarded_for = request.headers.get("x-forwarded-for", "")
    forwarded_ips = [normalized_ip(value) for value in forwarded_for.split(",")]
    forwarded_ips = [value for value in forwarded_ips if value]
    if forwarded_ips:
        return forwarded_ips[-1]
    return remote_host


def normalized_ip(value: str) -> Optional[str]:
    candidate = value.strip()
    if not candidate:
        return None
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        return None


def is_trusted_proxy(host: str) -> bool:
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return any(address in network for network in _trusted_proxy_networks)


def cleanup_rate_limit_hits(now: float, window_seconds: int) -> None:
    for key, hits in list(_rate_limit_hits.items()):
        while hits and now - hits[0] >= window_seconds:
            hits.popleft()
        if not hits:
            del _rate_limit_hits[key]

    if len(_rate_limit_hits) > RATE_LIMIT_MAX_KEYS:
        overflow = len(_rate_limit_hits) - RATE_LIMIT_MAX_KEYS
        oldest_keys = sorted(_rate_limit_hits, key=lambda key: _rate_limit_hits[key][-1] if _rate_limit_hits[key] else 0)[:overflow]
        for key in oldest_keys:
            _rate_limit_hits.pop(key, None)


def check_rate_limit(request: Request, *, limit: int, window_seconds: int) -> tuple[bool, int]:
    global _rate_limit_last_cleanup
    now = time.monotonic()
    if now - _rate_limit_last_cleanup >= RATE_LIMIT_CLEANUP_INTERVAL_SECONDS:
        cleanup_rate_limit_hits(now, window_seconds)
        _rate_limit_last_cleanup = now

    key = f"{request.url.path}:{rate_limit_identity(request)}"
    hits = _rate_limit_hits.setdefault(key, deque())
    while hits and now - hits[0] >= window_seconds:
        hits.popleft()
    if len(hits) >= limit:
        retry_after = max(1, math.ceil(window_seconds - (now - hits[0])))
        return False, retry_after
    hits.append(now)
    return True, 0


def column_exists(conn: Any, table: str, column: str) -> bool:
    if is_postgres():
        row = execute(
            conn,
            """
            SELECT 1
            FROM information_schema.columns
            WHERE table_name = ? AND column_name = ?
            LIMIT 1
            """,
            (table, column),
        ).fetchone()
        return row is not None

    rows = conn.execute(f"PRAGMA table_info({quote_identifier(table)})").fetchall()
    return any(row_to_dict(row).get("name") == column for row in rows)


def add_column_if_missing(conn: Any, table: str, column: str, definition: str) -> None:
    if not column_exists(conn, table, column):
        conn.execute(
            f"ALTER TABLE {quote_identifier(table)} "
            f"ADD COLUMN {quote_identifier(column)} {safe_column_definition(definition)}"
        )


def safe_column_definition(definition: str) -> str:
    if any(marker in definition for marker in (";", "--", "/*", "*/")):
        raise RuntimeError("Unsafe SQL column definition.")
    return definition


def ensure_schema_migrations(conn: Any) -> None:
    # Keeps existing local/dev databases usable as the ledger schema evolves.
    add_column_if_missing(conn, "users", "updated_at", "TEXT")
    execute(conn, "UPDATE users SET updated_at = COALESCE(updated_at, created_at)")
    add_column_if_missing(conn, "users", "apple_refresh_token", "TEXT")

    add_column_if_missing(conn, "credit_ledger", "source_id", "TEXT")
    add_column_if_missing(conn, "storekit_transactions", "environment", "TEXT")
    add_column_if_missing(conn, "storekit_transactions", "original_transaction_id", "TEXT")
    add_column_if_missing(conn, "storekit_transactions", "app_account_token", "TEXT")

    add_column_if_missing(conn, "transcriptions", "provider_account_id", "TEXT NOT NULL DEFAULT 'openai-primary'")
    add_column_if_missing(conn, "transcriptions", "input_tokens", "BIGINT")
    add_column_if_missing(conn, "transcriptions", "output_tokens", "BIGINT")
    add_column_if_missing(conn, "transcriptions", "pricing_basis", "TEXT NOT NULL DEFAULT 'duration_estimate'")

    conn.execute("CREATE INDEX IF NOT EXISTS credit_ledger_user_created_idx ON credit_ledger(user_id, created_at DESC)")
    conn.execute("CREATE INDEX IF NOT EXISTS credit_reservations_user_created_idx ON credit_reservations(user_id, created_at)")
    conn.execute("CREATE INDEX IF NOT EXISTS transcriptions_user_created_idx ON transcriptions(user_id, created_at DESC)")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS credit_ledger_source_id_unique_idx ON credit_ledger(source_id) WHERE source_id IS NOT NULL")


@contextmanager
def db() -> Any:
    if is_postgres():
        if pg_pool is None:
            raise HTTPException(status_code=500, detail="Postgres pool is not initialized.")
        with pg_pool.connection() as conn:
            with conn.transaction():
                yield conn
        return

    conn = sqlite3.connect(DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db() -> None:
    if is_postgres():
        with db() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id TEXT PRIMARY KEY,
                    apple_sub TEXT NOT NULL UNIQUE,
                    email TEXT,
                    full_name TEXT,
                    apple_refresh_token TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS credit_ledger (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    amount_usd_micros BIGINT NOT NULL,
                    kind TEXT NOT NULL,
                    description TEXT NOT NULL,
                    source_id TEXT UNIQUE,
                    created_at TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS credit_reservations (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    amount_usd_micros BIGINT NOT NULL,
                    kind TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS storekit_transactions (
                    transaction_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    product_id TEXT NOT NULL,
                    signed_transaction TEXT NOT NULL,
                    environment TEXT,
                    original_transaction_id TEXT,
                    app_account_token TEXT,
                    created_at TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS transcriptions (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    provider_account_id TEXT NOT NULL,
                    model TEXT NOT NULL,
                    audio_seconds DOUBLE PRECISION NOT NULL,
                    transcript TEXT NOT NULL,
                    input_tokens BIGINT,
                    output_tokens BIGINT,
                    cost_usd_micros BIGINT NOT NULL,
                    pricing_basis TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """
            )
            ensure_schema_migrations(conn)
        return

    with db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                apple_sub TEXT NOT NULL UNIQUE,
                email TEXT,
                full_name TEXT,
                apple_refresh_token TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS credit_ledger (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                amount_usd_micros INTEGER NOT NULL,
                kind TEXT NOT NULL,
                description TEXT NOT NULL,
                source_id TEXT UNIQUE,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS credit_reservations (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                amount_usd_micros INTEGER NOT NULL,
                kind TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS storekit_transactions (
                transaction_id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                product_id TEXT NOT NULL,
                signed_transaction TEXT NOT NULL,
                environment TEXT,
                original_transaction_id TEXT,
                app_account_token TEXT,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS transcriptions (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                provider_account_id TEXT NOT NULL DEFAULT 'openai-primary',
                model TEXT NOT NULL,
                audio_seconds REAL NOT NULL,
                transcript TEXT NOT NULL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cost_usd_micros INTEGER NOT NULL,
                pricing_basis TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            """
        )
        ensure_schema_migrations(conn)


def on_startup() -> None:
    global pg_pool
    if is_postgres():
        if ConnectionPool is None:
            raise RuntimeError("psycopg[binary,pool] is required when DATABASE_URL is Postgres.")
        pg_pool = ConnectionPool(
            DATABASE_URL,
            kwargs={"row_factory": dict_row},
            min_size=1,
            max_size=int(os.getenv("DATABASE_POOL_MAX_SIZE", "10")),
        )
    init_db()
    with db() as conn:
        clear_expired_credit_reservations(conn)
    logger.info(
        "startup_complete",
        extra={
            "database": "postgres" if is_postgres() else "sqlite-local",
            "rate_limit_enabled": RATE_LIMIT_ENABLED,
            "reservation_ttl_seconds": CREDIT_RESERVATION_TTL_SECONDS,
        },
    )


def on_shutdown() -> None:
    if pg_pool is not None:
        pg_pool.close()


def require_jwt_secret() -> None:
    if not JWT_SECRET:
        raise HTTPException(status_code=500, detail="JWT_SECRET is not configured.")


def require_openai_key() -> None:
    if not OPENAI_API_KEY:
        raise HTTPException(status_code=500, detail="OPENAI_API_KEY is not configured.")


def create_token(user: dict[str, Any]) -> str:
    require_jwt_secret()
    now = datetime.now(timezone.utc)
    payload = {
        "iss": JWT_ISSUER,
        "sub": user["id"],
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(days=JWT_TTL_DAYS)).timestamp()),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")


def current_user(authorization: Annotated[Optional[str], Header()] = None) -> dict[str, Any]:
    require_jwt_secret()
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.removeprefix("Bearer ").strip()
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"], issuer=JWT_ISSUER)
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail="Invalid bearer token.") from exc
    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(status_code=401, detail="Invalid bearer token.")
    with db() as conn:
        row = execute(conn, "SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="User no longer exists.")
    return row_to_dict(row)


def lock_user(conn: Any, user_id: str) -> None:
    if is_postgres():
        execute(conn, "SELECT id FROM users WHERE id = ? FOR UPDATE", (user_id,)).fetchone()


def clear_expired_credit_reservations(conn: Any) -> None:
    execute(conn, "DELETE FROM credit_reservations WHERE created_at < ?", (reservation_cutoff_iso(),))


def reservation_cutoff_iso() -> str:
    cutoff = datetime.now(timezone.utc) - timedelta(seconds=CREDIT_RESERVATION_TTL_SECONDS)
    return cutoff.isoformat()


def ledger_balance_for_user(conn: Any, user_id: str) -> int:
    row = execute(
        conn,
        "SELECT COALESCE(SUM(amount_usd_micros), 0) AS balance FROM credit_ledger WHERE user_id = ?",
        (user_id,),
    ).fetchone()
    value = row_to_dict(row).get("balance", 0) if row else 0
    return int(value or 0)


def reserved_balance_for_user(conn: Any, user_id: str) -> int:
    row = execute(
        conn,
        """
        SELECT COALESCE(SUM(amount_usd_micros), 0) AS reserved
        FROM credit_reservations
        WHERE user_id = ? AND created_at >= ?
        """,
        (user_id, reservation_cutoff_iso()),
    ).fetchone()
    value = row_to_dict(row).get("reserved", 0) if row else 0
    return int(value or 0)


def balance_for_user(conn: Any, user_id: str) -> int:
    return ledger_balance_for_user(conn, user_id) - reserved_balance_for_user(conn, user_id)


def balance_payload(balance: int) -> BalancePayload:
    return BalancePayload(
        balance_usd_micros=balance,
        balance_credit_units=credit_units_from_usd_micros(balance),
        formatted=format_credits(balance),
    )


def insert_ledger(
    conn: Any,
    *,
    user_id: str,
    amount_usd_micros: int,
    kind: str,
    description: str,
    source_id: Optional[str] = None,
) -> None:
    execute(
        conn,
        """
        INSERT INTO credit_ledger (id, user_id, amount_usd_micros, kind, description, source_id, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (str(uuid.uuid4()), user_id, amount_usd_micros, kind, description, source_id, utc_now()),
    )


def reserve_credit(conn: Any, *, user_id: str, amount_usd_micros: int, kind: str) -> str:
    lock_user(conn, user_id)
    clear_expired_credit_reservations(conn)
    balance = balance_for_user(conn, user_id)
    if balance < amount_usd_micros:
        raise HTTPException(status_code=402, detail=f"Insufficient credit. Need at least {format_credits(amount_usd_micros)}.")
    reservation_id = str(uuid.uuid4())
    execute(
        conn,
        """
        INSERT INTO credit_reservations (id, user_id, amount_usd_micros, kind, created_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        (reservation_id, user_id, amount_usd_micros, kind, utc_now()),
    )
    return reservation_id


def release_credit_reservation(conn: Any, *, reservation_id: str, user_id: str) -> None:
    execute(conn, "DELETE FROM credit_reservations WHERE id = ? AND user_id = ?", (reservation_id, user_id))


def apple_signin_private_key_pem() -> str:
    if APPLE_SIGNIN_PRIVATE_KEY:
        return APPLE_SIGNIN_PRIVATE_KEY.replace("\\n", "\n")
    if APPLE_SIGNIN_PRIVATE_KEY_B64:
        return base64.b64decode(APPLE_SIGNIN_PRIVATE_KEY_B64).decode("utf-8")
    if APPLE_SIGNIN_PRIVATE_KEY_PATH:
        with open(APPLE_SIGNIN_PRIVATE_KEY_PATH, "r", encoding="utf-8") as handle:
            return handle.read()
    return ""


def apple_signin_configured() -> bool:
    return bool(APPLE_SIGNIN_TEAM_ID and APPLE_SIGNIN_KEY_ID and apple_signin_private_key_pem())


def generate_apple_client_secret() -> str:
    # ES256 JWT used as the client_secret for Apple's token and revoke endpoints.
    now = datetime.now(timezone.utc)
    claims = {
        "iss": APPLE_SIGNIN_TEAM_ID,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=10)).timestamp()),
        "aud": APPLE_ISSUER,
        "sub": APPLE_CLIENT_ID,
    }
    return jwt.encode(
        claims,
        apple_signin_private_key_pem(),
        algorithm="ES256",
        headers={"kid": APPLE_SIGNIN_KEY_ID},
    )


def exchange_apple_authorization_code(authorization_code: str) -> Optional[str]:
    # Trades the one-time auth code from Sign in with Apple for a refresh token
    # so the account can later be revoked on deletion. Best-effort: returns None
    # if credentials are not configured or Apple rejects the exchange.
    if not authorization_code or not apple_signin_configured():
        return None
    try:
        response = httpx.post(
            APPLE_TOKEN_URL,
            data={
                "client_id": APPLE_CLIENT_ID,
                "client_secret": generate_apple_client_secret(),
                "code": authorization_code,
                "grant_type": "authorization_code",
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=10.0,
        )
    except httpx.HTTPError as exc:
        logger.warning("apple_code_exchange_failed", extra={"error": str(exc)})
        return None
    if response.status_code != 200:
        logger.warning(
            "apple_code_exchange_rejected",
            extra={"status_code": response.status_code, "body": response.text[:500]},
        )
        return None
    return response.json().get("refresh_token")


def revoke_apple_token(refresh_token: str) -> bool:
    # Revokes the user's Apple token grant on account deletion. Best-effort.
    if not refresh_token or not apple_signin_configured():
        return False
    try:
        response = httpx.post(
            APPLE_REVOKE_URL,
            data={
                "client_id": APPLE_CLIENT_ID,
                "client_secret": generate_apple_client_secret(),
                "token": refresh_token,
                "token_type_hint": "refresh_token",
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=10.0,
        )
    except httpx.HTTPError as exc:
        logger.warning("apple_token_revoke_failed", extra={"error": str(exc)})
        return False
    if response.status_code != 200:
        logger.warning(
            "apple_token_revoke_rejected",
            extra={"status_code": response.status_code, "body": response.text[:500]},
        )
        return False
    return True


def grant_signup_credit_if_needed(user_id: str) -> None:
    # One-time welcome credit, idempotent via the unique source_id. Applied on
    # every sign-in that finds it missing so a grant that failed (or a crash
    # right after account creation) self-heals on the next sign-in. Runs in its
    # own transaction: on Postgres a failed statement aborts the enclosing
    # transaction, so this must never share one with the sign-in flow.
    if not SIGNUP_GRANT_ENABLED or SIGNUP_GRANT_USD_MICROS <= 0:
        return
    source_id = f"signup:{user_id}"
    try:
        with db() as conn:
            row = execute(conn, "SELECT 1 FROM credit_ledger WHERE source_id = ?", (source_id,)).fetchone()
            if row:
                return
            insert_ledger(
                conn,
                user_id=user_id,
                amount_usd_micros=SIGNUP_GRANT_USD_MICROS,
                kind="signup_grant",
                description="Welcome credit",
                source_id=source_id,
            )
    except Exception as exc:  # noqa: BLE001 - signup credit must never block sign-in
        if is_unique_violation(exc):
            return
        logger.exception("signup_grant_failed", extra={"user_id": user_id})


def verify_apple_identity_token(identity_token: str) -> dict[str, Any]:
    if APPLE_AUTH_DEV_BYPASS and identity_token.startswith("dev:"):
        sub = identity_token.removeprefix("dev:") or "local-dev-user"
        return {"sub": sub, "email": f"{sub}@example.dev"}
    try:
        signing_key = apple_jwks.get_signing_key_from_jwt(identity_token)
        return jwt.decode(
            identity_token,
            signing_key.key,
            algorithms=["RS256"],
            audience=APPLE_CLIENT_ID,
            issuer=APPLE_ISSUER,
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail="Invalid Apple identity token.") from exc


def upsert_apple_user(
    payload: dict[str, Any],
    request: AppleAuthRequest,
    refresh_token: Optional[str] = None,
) -> dict[str, Any]:
    apple_sub = str(payload.get("sub") or "").strip()
    if not apple_sub:
        raise HTTPException(status_code=401, detail="Apple identity token is missing sub.")
    email = request.email or payload.get("email")
    full_name = request.full_name

    for attempt in (0, 1):
        try:
            with db() as conn:
                row = execute(conn, "SELECT * FROM users WHERE apple_sub = ?", (apple_sub,)).fetchone()
                if row:
                    user = row_to_dict(row)
                    execute(
                        conn,
                        "UPDATE users SET email = COALESCE(?, email), full_name = COALESCE(?, full_name), "
                        "apple_refresh_token = COALESCE(?, apple_refresh_token), updated_at = ? WHERE id = ?",
                        (email, full_name, refresh_token, utc_now(), user["id"]),
                    )
                    return row_to_dict(execute(conn, "SELECT * FROM users WHERE id = ?", (user["id"],)).fetchone())

                user_id = str(uuid.uuid4())
                now = utc_now()
                execute(
                    conn,
                    "INSERT INTO users (id, apple_sub, email, full_name, apple_refresh_token, created_at, updated_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (user_id, apple_sub, email, full_name, refresh_token, now, now),
                )
                return row_to_dict(execute(conn, "SELECT * FROM users WHERE id = ?", (user_id,)).fetchone())
        except Exception as exc:
            # A concurrent first sign-in can win the INSERT race on apple_sub;
            # retry once so the UPDATE path picks up the existing row.
            if attempt == 0 and is_unique_violation(exc):
                continue
            raise
    raise HTTPException(status_code=500, detail="Could not create the user account.")


def decode_unverified_storekit_payload(jws: str) -> dict[str, Any]:
    parts = jws.split(".")
    if len(parts) != 3:
        raise HTTPException(status_code=400, detail="StoreKit transaction must be a compact JWS.")
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(payload.encode("utf-8")))
    except (ValueError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=400, detail="Invalid StoreKit transaction payload.") from exc


def load_apple_root_certificates() -> list[bytes]:
    certs: list[bytes] = []
    for path in [item.strip() for item in APPLE_ROOT_CERTIFICATE_PATHS.split(",") if item.strip()]:
        with open(path, "rb") as handle:
            certs.append(handle.read())
    for encoded in [item.strip() for item in APPLE_ROOT_CERTIFICATE_PEMS_B64.split(",") if item.strip()]:
        certs.append(base64.b64decode(encoded))
    return certs


def storekit_environment() -> Any:
    if Environment is None:
        return None
    mapping = {
        "PRODUCTION": Environment.PRODUCTION,
        "SANDBOX": Environment.SANDBOX,
        "XCODE": Environment.XCODE,
        "LOCAL_TESTING": Environment.LOCAL_TESTING,
    }
    return mapping.get(APPLE_STOREKIT_ENVIRONMENT, Environment.PRODUCTION)


def verify_storekit_payload(jws: str) -> dict[str, Any]:
    if STOREKIT_VERIFICATION_MODE == "strict" and not ALLOW_UNVERIFIED_STOREKIT_JWS:
        if SignedDataVerifier is None or Environment is None:
            raise HTTPException(status_code=500, detail="App Store Server Library is not installed.")
        certs = load_apple_root_certificates()
        if not certs:
            raise HTTPException(status_code=500, detail="APPLE_ROOT_CERTIFICATE_PATHS or APPLE_ROOT_CERTIFICATE_PEMS_B64 is required.")
        verifier = SignedDataVerifier(
            certs,
            True,
            storekit_environment(),
            APPLE_BUNDLE_ID,
            int(APPLE_APP_APPLE_ID) if APPLE_APP_APPLE_ID else None,
        )
        try:
            decoded = verifier.verify_and_decode_signed_transaction(jws)
        except Exception as exc:
            raise HTTPException(status_code=401, detail="Invalid StoreKit transaction signature.") from exc
        return {
            "product_id": decoded.productId,
            "transaction_id": decoded.transactionId,
            "original_transaction_id": decoded.originalTransactionId,
            "bundle_id": decoded.bundleId,
            "environment": decoded.rawEnvironment or getattr(decoded.environment, "value", None),
            "app_account_token": decoded.appAccountToken,
        }

    payload = decode_unverified_storekit_payload(jws)
    return {
        "product_id": payload.get("productId") or payload.get("product_id"),
        "transaction_id": payload.get("transactionId") or payload.get("transaction_id"),
        "original_transaction_id": payload.get("originalTransactionId") or payload.get("original_transaction_id"),
        "bundle_id": payload.get("bundleId") or payload.get("bundle_id"),
        "environment": payload.get("environment"),
        "app_account_token": payload.get("appAccountToken") or payload.get("app_account_token"),
    }


def resolve_model(model: Optional[str]) -> str:
    selected = (model or OPENAI_TRANSCRIBE_MODEL).strip()
    if selected not in MODEL_PRICING:
        raise HTTPException(status_code=400, detail=f"Unsupported transcription model: {selected}")
    return selected


def extract_usage(payload: dict[str, Any]) -> tuple[Optional[int], Optional[int]]:
    usage = payload.get("usage") or {}
    input_tokens = usage.get("input_tokens") or usage.get("audio_tokens") or usage.get("prompt_tokens")
    output_tokens = usage.get("output_tokens") or usage.get("completion_tokens")
    return (int(input_tokens) if input_tokens else None, int(output_tokens) if output_tokens else None)


def estimate_text_tokens(text: str) -> int:
    return max(1, math.ceil(len(text) / 4))


def apply_cost_markup(cost_usd_micros: int) -> int:
    if COST_MARKUP_BPS:
        return math.ceil(cost_usd_micros * (10_000 + COST_MARKUP_BPS) / 10_000)
    return cost_usd_micros


def calculate_cost(
    *,
    model: str,
    audio_seconds: float,
    transcript: str,
    input_tokens: Optional[int],
    output_tokens: Optional[int],
) -> tuple[int, str, int, int]:
    pricing = MODEL_PRICING[model]
    if pricing["basis"] == "audio_minutes":
        minutes = max(audio_seconds, 1.0) / 60
        cost = apply_cost_markup(math.ceil(minutes * pricing["per_minute_usd_micros"]))
        return max(cost, 1), "duration", math.ceil(minutes * 60), 0

    charged_input = input_tokens or math.ceil(max(audio_seconds, 1.0) * FALLBACK_AUDIO_TOKENS_PER_SECOND)
    charged_output = output_tokens or estimate_text_tokens(transcript)
    input_cost = charged_input * pricing["input_per_million_usd_micros"] / 1_000_000
    output_cost = charged_output * pricing["output_per_million_usd_micros"] / 1_000_000
    cost = apply_cost_markup(math.ceil(input_cost + output_cost))
    basis = "reported_usage" if input_tokens or output_tokens else "duration_estimate"
    return max(cost, 1), basis, charged_input, charged_output


def estimate_preflight_cost(model: str, audio_seconds: float) -> int:
    cost, _, _, _ = calculate_cost(
        model=model,
        audio_seconds=max(audio_seconds, 1.0),
        transcript="estimated transcript budget",
        input_tokens=None,
        output_tokens=max(64, math.ceil(audio_seconds * 4)),
    )
    return max(cost, 1)


def estimate_reservation_cost(model: str, audio_seconds: float, audio_bytes: int) -> int:
    inferred_seconds = max(audio_seconds, audio_bytes / AUDIO_BYTES_PER_SECOND_FLOOR)
    estimated = estimate_preflight_cost(model, inferred_seconds)
    return max(estimated, MIN_TRANSCRIPTION_RESERVATION_USD_MICROS)


async def transcribe_audio(audio: bytes, filename: str, content_type: Optional[str], model: str, language: Optional[str]) -> dict[str, Any]:
    require_openai_key()
    headers = {"Authorization": f"Bearer {OPENAI_API_KEY}"}
    data: dict[str, str] = {"model": model, "response_format": "json"}
    if language:
        data["language"] = language
    files = {"file": (filename, audio, content_type or "audio/m4a")}
    async with httpx.AsyncClient(timeout=httpx.Timeout(120.0)) as client:
        response = await client.post(f"{OPENAI_BASE_URL}/v1/audio/transcriptions", headers=headers, data=data, files=files)
    if response.status_code >= 400:
        # Log the provider response server-side only; its body can include
        # account-specific details that must not reach the client.
        logger.error(
            "transcription_provider_error",
            extra={"status_code": response.status_code, "body": response.text[:500]},
        )
        raise HTTPException(status_code=502, detail="Transcription provider request failed.")
    payload = response.json()
    transcript = (payload.get("text") or "").strip()
    if not transcript:
        raise HTTPException(status_code=502, detail="Transcription returned empty text.")
    return payload


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "voicetype-api",
        "model": OPENAI_TRANSCRIBE_MODEL,
        "database": "postgres" if is_postgres() else "sqlite-local",
        "storekit_verification_mode": STOREKIT_VERIFICATION_MODE,
    }


@app.get("/privacy", response_class=HTMLResponse)
@app.get("/privacy-policy", response_class=HTMLResponse, include_in_schema=False)
@app.head("/privacy", response_class=HTMLResponse, include_in_schema=False)
@app.head("/privacy-policy", response_class=HTMLResponse, include_in_schema=False)
def privacy_policy() -> HTMLResponse:
    return HTMLResponse(content=privacy_policy_html())


@app.get("/health/ready")
def readiness() -> JSONResponse:
    checks: dict[str, Any] = {
        "jwt_secret": bool(JWT_SECRET),
        "openai_api_key": bool(OPENAI_API_KEY),
        "database": False,
        "storekit_strict": STOREKIT_VERIFICATION_MODE == "strict" and not ALLOW_UNVERIFIED_STOREKIT_JWS,
        "storekit_app_account_token_required": REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN,
        "apple_app_id": bool(APPLE_APP_APPLE_ID),
        "apple_root_certificates": bool(APPLE_ROOT_CERTIFICATE_PATHS or APPLE_ROOT_CERTIFICATE_PEMS_B64),
        "dev_credit_disabled": not ALLOW_DEV_CREDIT,
    }
    try:
        with db() as conn:
            execute(conn, "SELECT 1").fetchone()
        checks["database"] = True
    except Exception as exc:
        checks["database_error"] = exc.__class__.__name__

    ok = all(value is True for value in checks.values() if isinstance(value, bool))
    return JSONResponse(
        status_code=200 if ok else 503,
        content={
            "ok": ok,
            "service": "voicetype-api",
            "model": OPENAI_TRANSCRIBE_MODEL,
            "checks": checks,
        },
    )


@app.post("/v1/auth/apple", response_model=AuthResponse)
def auth_apple(request: AppleAuthRequest) -> AuthResponse:
    apple_payload = verify_apple_identity_token(request.identity_token)
    refresh_token = exchange_apple_authorization_code(request.authorization_code) if request.authorization_code else None
    user = upsert_apple_user(apple_payload, request, refresh_token=refresh_token)
    grant_signup_credit_if_needed(user["id"])
    with db() as conn:
        balance = balance_for_user(conn, user["id"])
    return AuthResponse(token=create_token(user), user=AuthUser(id=user["id"], email=user.get("email")), balance=balance_payload(balance))


@app.get("/v1/me")
def me(user: Annotated[dict[str, Any], Depends(current_user)]) -> dict[str, Any]:
    with db() as conn:
        balance = balance_for_user(conn, user["id"])
    return {"user": AuthUser(id=user["id"], email=user.get("email")), "balance": balance_payload(balance)}


@app.delete("/v1/account")
def delete_account(user: Annotated[dict[str, Any], Depends(current_user)]) -> dict[str, Any]:
    # App Store Guideline 5.1.1(v): account deletion from inside the app.
    # Revokes the Apple token grant (best-effort) then removes the user row.
    # Ledger, reservations, StoreKit transactions, and transcriptions are
    # removed by ON DELETE CASCADE.
    refresh_token = user.get("apple_refresh_token")
    revoked = revoke_apple_token(refresh_token) if refresh_token else False
    with db() as conn:
        execute(conn, "DELETE FROM users WHERE id = ?", (user["id"],))
    logger.info("account_deleted", extra={"user_id": user["id"], "apple_token_revoked": revoked})
    return {"ok": True, "apple_token_revoked": revoked}


@app.get("/v1/billing/products")
def products() -> dict[str, list[CreditProduct]]:
    return {"products": [CreditProduct(**product_payload(product)) for product in product_catalog()]}


@app.get("/v1/billing/ledger", response_model=LedgerResponse)
def ledger(user: Annotated[dict[str, Any], Depends(current_user)], limit: int = 50) -> LedgerResponse:
    safe_limit = min(max(limit, 1), 200)
    with db() as conn:
        balance = balance_for_user(conn, user["id"])
        rows = execute(
            conn,
            f"""
            SELECT id, amount_usd_micros, kind, description, created_at
            FROM credit_ledger
            WHERE user_id = ?
            ORDER BY created_at DESC
            LIMIT {safe_limit}
            """,
            (user["id"],),
        ).fetchall()
    return LedgerResponse(balance=balance_payload(balance), items=[LedgerEntry(**row_to_dict(row)) for row in rows])


@app.post("/v1/billing/storekit/transactions", response_model=PurchaseCreditResponse)
def storekit_transaction(
    request: StoreKitTransactionRequest,
    user: Annotated[dict[str, Any], Depends(current_user)],
) -> PurchaseCreditResponse:
    payload = verify_storekit_payload(request.signed_transaction)
    product_id = str(payload.get("product_id") or "")
    transaction_id = str(payload.get("transaction_id") or "")
    bundle_id = payload.get("bundle_id")
    app_account_token = payload.get("app_account_token")

    if not transaction_id:
        raise HTTPException(status_code=400, detail="StoreKit transaction is missing transactionId.")
    if bundle_id and bundle_id != APPLE_BUNDLE_ID:
        raise HTTPException(status_code=400, detail="StoreKit transaction bundle id does not match this app.")
    if REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN and not app_account_token:
        raise HTTPException(status_code=400, detail="StoreKit transaction is missing appAccountToken.")
    if app_account_token and str(app_account_token).lower() != str(user["id"]).lower():
        raise HTTPException(status_code=403, detail="StoreKit transaction belongs to another app account.")

    product = product_by_id(product_id)
    credit = int(product["credit_usd_micros"])

    with db() as conn:
        lock_user(conn, user["id"])
        existing = execute(conn, "SELECT user_id FROM storekit_transactions WHERE transaction_id = ?", (transaction_id,)).fetchone()
        if existing:
            existing_user_id = row_to_dict(existing)["user_id"]
            if existing_user_id != user["id"]:
                raise HTTPException(status_code=409, detail="Transaction was already processed for another user.")
            logger.info("storekit_replay_ignored", extra={"user_id": user["id"], "transaction_id": transaction_id})
            return PurchaseCreditResponse(
                balance=balance_payload(balance_for_user(conn, user["id"])),
                granted_usd_micros=0,
                granted_credit_units=0,
                already_processed=True,
            )
        execute(
            conn,
            """
            INSERT INTO storekit_transactions
                (transaction_id, user_id, product_id, signed_transaction, environment,
                 original_transaction_id, app_account_token, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                transaction_id,
                user["id"],
                product_id,
                request.signed_transaction,
                payload.get("environment"),
                payload.get("original_transaction_id"),
                str(app_account_token) if app_account_token else None,
                utc_now(),
            ),
        )
        insert_ledger(
            conn,
            user_id=user["id"],
            amount_usd_micros=credit,
            kind="storekit_purchase",
            description=f"Credit pack: {product['display_name']}",
            source_id=f"storekit:{transaction_id}",
        )
        balance = balance_for_user(conn, user["id"])

    logger.info(
        "storekit_credit_granted",
        extra={"user_id": user["id"], "transaction_id": transaction_id, "product_id": product_id, "credit_usd_micros": credit},
    )
    return PurchaseCreditResponse(
        balance=balance_payload(balance),
        granted_usd_micros=credit,
        granted_credit_units=credit_units_from_usd_micros(credit),
        already_processed=False,
    )


@app.post("/v1/billing/dev-credit", response_model=PurchaseCreditResponse)
def grant_dev_credit(
    request: DevCreditRequest,
    user: Annotated[dict[str, Any], Depends(current_user)],
    x_voicetype_dev_credit_key: Annotated[Optional[str], Header(alias="X-VoiceType-Dev-Credit-Key")] = None,
) -> PurchaseCreditResponse:
    if not ALLOW_DEV_CREDIT:
        raise HTTPException(status_code=404, detail="Dev credit is disabled.")
    if DEV_CREDIT_SHARED_SECRET and x_voicetype_dev_credit_key != DEV_CREDIT_SHARED_SECRET:
        raise HTTPException(status_code=404, detail="Dev credit is disabled.")
    if request.amount_usd_micros > DEV_CREDIT_MAX_USD_MICROS:
        raise HTTPException(status_code=400, detail=f"Dev credit is capped at {format_credits(DEV_CREDIT_MAX_USD_MICROS)}.")
    with db() as conn:
        lock_user(conn, user["id"])
        insert_ledger(
            conn,
            user_id=user["id"],
            amount_usd_micros=request.amount_usd_micros,
            kind="dev_credit",
            description="Local development credit",
            source_id=f"dev:{uuid.uuid4()}",
        )
        balance = balance_for_user(conn, user["id"])
    logger.info("dev_credit_granted", extra={"user_id": user["id"], "amount_usd_micros": request.amount_usd_micros})
    return PurchaseCreditResponse(
        balance=balance_payload(balance),
        granted_usd_micros=request.amount_usd_micros,
        granted_credit_units=credit_units_from_usd_micros(request.amount_usd_micros),
        already_processed=False,
    )


@app.post("/v1/transcriptions", response_model=TranscriptionResponse)
async def create_transcription(
    user: Annotated[dict[str, Any], Depends(current_user)],
    file: Annotated[UploadFile, File()],
    audio_seconds: Annotated[float, Form(ge=0, le=86400, allow_inf_nan=False)] = 0,
    language: Annotated[Optional[str], Form()] = None,
    model: Annotated[Optional[str], Form()] = None,
) -> JSONResponse:
    selected_model = resolve_model(model)
    audio = await file.read()
    if not audio:
        raise HTTPException(status_code=400, detail="Audio file is empty.")
    if len(audio) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail=f"Audio file exceeds {MAX_AUDIO_BYTES} bytes.")

    reservation_cost = estimate_reservation_cost(selected_model, audio_seconds, len(audio))
    transcription_id = str(uuid.uuid4())
    with db() as conn:
        reservation_id = reserve_credit(
            conn,
            user_id=user["id"],
            amount_usd_micros=reservation_cost,
            kind="transcription",
        )

    try:
        payload = await transcribe_audio(audio, file.filename or "recording.m4a", file.content_type, selected_model, language)
    except Exception:
        with db() as conn:
            release_credit_reservation(conn, reservation_id=reservation_id, user_id=user["id"])
        logger.exception("transcription_provider_failed", extra={"user_id": user["id"], "model": selected_model})
        raise
    transcript = payload["text"].strip()
    input_tokens, output_tokens = extract_usage(payload)
    cost, pricing_basis, charged_input, charged_output = calculate_cost(
        model=selected_model,
        audio_seconds=audio_seconds,
        transcript=transcript,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
    )

    charged_cost = cost
    with db() as conn:
        lock_user(conn, user["id"])
        extra_cost = max(0, cost - reservation_cost)
        available_balance = balance_for_user(conn, user["id"])
        if extra_cost > available_balance:
            charged_cost = reservation_cost + max(0, available_balance)
            logger.warning(
                "transcription_charge_capped_by_available_balance",
                extra={
                    "user_id": user["id"],
                    "model": selected_model,
                    "estimated_cost": reservation_cost,
                    "calculated_cost": cost,
                    "charged_cost": charged_cost,
                },
            )
        execute(
            conn,
            """
            INSERT INTO transcriptions
                (id, user_id, provider_account_id, model, audio_seconds, transcript, input_tokens,
                 output_tokens, cost_usd_micros, pricing_basis, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                transcription_id,
                user["id"],
                OPENAI_PROVIDER_ACCOUNT_ID,
                selected_model,
                float(audio_seconds),
                transcript,
                charged_input,
                charged_output,
                charged_cost,
                pricing_basis,
                utc_now(),
            ),
        )
        insert_ledger(
            conn,
            user_id=user["id"],
            amount_usd_micros=-charged_cost,
            kind="transcription",
            description=f"{selected_model} transcription",
            source_id=f"transcription:{transcription_id}",
        )
        release_credit_reservation(conn, reservation_id=reservation_id, user_id=user["id"])
        balance = balance_for_user(conn, user["id"])

    logger.info(
        "transcription_completed",
        extra={
            "user_id": user["id"],
            "model": selected_model,
            "cost_usd_micros": charged_cost,
            "pricing_basis": pricing_basis,
        },
    )
    return JSONResponse(
        TranscriptionResponse(
            id=transcription_id,
            transcript=transcript,
            model=selected_model,
            charge=ChargePayload(
                cost_usd_micros=charged_cost,
                cost_credit_units=credit_units_from_usd_micros(charged_cost),
                formatted=format_credits(charged_cost),
                pricing_basis=pricing_basis,
            ),
            balance=balance_payload(balance),
        ).model_dump()
    )
