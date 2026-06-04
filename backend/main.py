from __future__ import annotations

import base64
import json
import math
import os
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from typing import Annotated, Any, Optional

import httpx
import jwt
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse
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


def default_cost_markup_bps() -> int:
    if APPLE_COMMISSION_BPS >= 10_000:
        raise RuntimeError("APPLE_COMMISSION_BPS must be less than 10000.")
    gross_multiplier_bps = math.ceil((10_000 + TARGET_PROFIT_MARGIN_BPS) * 10_000 / (10_000 - APPLE_COMMISSION_BPS))
    return max(0, gross_multiplier_bps - 10_000)


DEFAULT_COST_MARKUP_BPS = default_cost_markup_bps()
COST_MARKUP_BPS = int(os.getenv("COST_MARKUP_BPS", str(DEFAULT_COST_MARKUP_BPS)))


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


app = FastAPI(title="VoiceType API", version="0.2.0")
apple_jwks = PyJWKClient(APPLE_JWKS_URL)
pg_pool: Optional[Any] = None


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


def row_to_dict(row: Any) -> dict[str, Any]:
    return dict(row) if row is not None else {}


def execute(conn: Any, query: str, params: tuple[Any, ...] = ()) -> Any:
    return conn.execute(sql(query), params)


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

    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    return any(row_to_dict(row).get("name") == column for row in rows)


def add_column_if_missing(conn: Any, table: str, column: str, definition: str) -> None:
    if not column_exists(conn, table, column):
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")


def ensure_schema_migrations(conn: Any) -> None:
    # Keeps existing local/dev databases usable as the ledger schema evolves.
    add_column_if_missing(conn, "users", "updated_at", "TEXT")
    execute(conn, "UPDATE users SET updated_at = COALESCE(updated_at, created_at)")

    add_column_if_missing(conn, "credit_ledger", "source_id", "TEXT")
    add_column_if_missing(conn, "storekit_transactions", "environment", "TEXT")
    add_column_if_missing(conn, "storekit_transactions", "original_transaction_id", "TEXT")
    add_column_if_missing(conn, "storekit_transactions", "app_account_token", "TEXT")

    add_column_if_missing(conn, "transcriptions", "provider_account_id", "TEXT NOT NULL DEFAULT 'openai-primary'")
    add_column_if_missing(conn, "transcriptions", "input_tokens", "BIGINT")
    add_column_if_missing(conn, "transcriptions", "output_tokens", "BIGINT")
    add_column_if_missing(conn, "transcriptions", "pricing_basis", "TEXT NOT NULL DEFAULT 'duration_estimate'")

    conn.execute("CREATE INDEX IF NOT EXISTS credit_ledger_user_created_idx ON credit_ledger(user_id, created_at DESC)")
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


@app.on_event("startup")
def on_startup() -> None:
    global pg_pool
    if is_postgres():
        if ConnectionPool is None:
            raise RuntimeError("psycopg[binary,pool] is required when DATABASE_URL is Postgres.")
        pg_pool = ConnectionPool(DATABASE_URL, kwargs={"row_factory": dict_row}, min_size=1, max_size=int(os.getenv("DATABASE_POOL_MAX_SIZE", "10")))
    init_db()


@app.on_event("shutdown")
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


def balance_for_user(conn: Any, user_id: str) -> int:
    row = execute(
        conn,
        "SELECT COALESCE(SUM(amount_usd_micros), 0) AS balance FROM credit_ledger WHERE user_id = ?",
        (user_id,),
    ).fetchone()
    value = row_to_dict(row).get("balance", 0) if row else 0
    return int(value or 0)


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


def upsert_apple_user(payload: dict[str, Any], request: AppleAuthRequest) -> dict[str, Any]:
    apple_sub = str(payload.get("sub") or "").strip()
    if not apple_sub:
        raise HTTPException(status_code=401, detail="Apple identity token is missing sub.")
    email = request.email or payload.get("email")
    full_name = request.full_name

    with db() as conn:
        row = execute(conn, "SELECT * FROM users WHERE apple_sub = ?", (apple_sub,)).fetchone()
        if row:
            user = row_to_dict(row)
            execute(
                conn,
                "UPDATE users SET email = COALESCE(?, email), full_name = COALESCE(?, full_name), updated_at = ? WHERE id = ?",
                (email, full_name, utc_now(), user["id"]),
            )
            return row_to_dict(execute(conn, "SELECT * FROM users WHERE id = ?", (user["id"],)).fetchone())

        user_id = str(uuid.uuid4())
        now = utc_now()
        execute(
            conn,
            "INSERT INTO users (id, apple_sub, email, full_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            (user_id, apple_sub, email, full_name, now, now),
        )
        return row_to_dict(execute(conn, "SELECT * FROM users WHERE id = ?", (user_id,)).fetchone())


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
        raise HTTPException(status_code=502, detail=response.text)
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


@app.post("/v1/auth/apple", response_model=AuthResponse)
def auth_apple(request: AppleAuthRequest) -> AuthResponse:
    apple_payload = verify_apple_identity_token(request.identity_token)
    user = upsert_apple_user(apple_payload, request)
    with db() as conn:
        balance = balance_for_user(conn, user["id"])
    return AuthResponse(token=create_token(user), user=AuthUser(id=user["id"], email=user.get("email")), balance=balance_payload(balance))


@app.get("/v1/me")
def me(user: Annotated[dict[str, Any], Depends(current_user)]) -> dict[str, Any]:
    with db() as conn:
        balance = balance_for_user(conn, user["id"])
    return {"user": AuthUser(id=user["id"], email=user.get("email")), "balance": balance_payload(balance)}


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
    audio_seconds: Annotated[float, Form()] = 0,
    language: Annotated[Optional[str], Form()] = None,
    model: Annotated[Optional[str], Form()] = None,
) -> JSONResponse:
    selected_model = resolve_model(model)
    audio = await file.read()
    if not audio:
        raise HTTPException(status_code=400, detail="Audio file is empty.")
    if len(audio) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail=f"Audio file exceeds {MAX_AUDIO_BYTES} bytes.")

    preflight_cost = estimate_preflight_cost(selected_model, audio_seconds)
    with db() as conn:
        lock_user(conn, user["id"])
        balance = balance_for_user(conn, user["id"])
        if balance < preflight_cost:
            raise HTTPException(status_code=402, detail=f"Insufficient credit. Need at least {format_credits(preflight_cost)}.")

    payload = await transcribe_audio(audio, file.filename or "recording.m4a", file.content_type, selected_model, language)
    transcript = payload["text"].strip()
    input_tokens, output_tokens = extract_usage(payload)
    cost, pricing_basis, charged_input, charged_output = calculate_cost(
        model=selected_model,
        audio_seconds=audio_seconds,
        transcript=transcript,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
    )

    transcription_id = str(uuid.uuid4())
    with db() as conn:
        lock_user(conn, user["id"])
        balance = balance_for_user(conn, user["id"])
        if balance < cost:
            raise HTTPException(status_code=402, detail=f"Insufficient credit after final usage calculation. Need {format_credits(cost)}.")
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
                cost,
                pricing_basis,
                utc_now(),
            ),
        )
        insert_ledger(
            conn,
            user_id=user["id"],
            amount_usd_micros=-cost,
            kind="transcription",
            description=f"{selected_model} transcription",
            source_id=f"transcription:{transcription_id}",
        )
        balance = balance_for_user(conn, user["id"])

    return JSONResponse(
        TranscriptionResponse(
            id=transcription_id,
            transcript=transcript,
            model=selected_model,
            charge=ChargePayload(
                cost_usd_micros=cost,
                cost_credit_units=credit_units_from_usd_micros(cost),
                formatted=format_credits(cost),
                pricing_basis=pricing_basis,
            ),
            balance=balance_payload(balance),
        ).model_dump()
    )
