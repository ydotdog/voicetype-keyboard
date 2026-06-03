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


OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "https://api.openai.com").rstrip("/")
OPENAI_TRANSCRIBE_MODEL = os.getenv("OPENAI_TRANSCRIBE_MODEL", "gpt-4o-mini-transcribe")

DATABASE_PATH = os.getenv("DATABASE_PATH", "./voicetype.sqlite3")
JWT_SECRET = os.getenv("JWT_SECRET", "")
JWT_ISSUER = os.getenv("JWT_ISSUER", "voicetype")
JWT_TTL_DAYS = int(os.getenv("JWT_TTL_DAYS", "365"))

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_CLIENT_ID = os.getenv("APPLE_CLIENT_ID", "com.kyleqi.voicetype")
APPLE_AUTH_DEV_BYPASS = os.getenv("APPLE_AUTH_DEV_BYPASS", "").lower() in {"1", "true", "yes"}

ALLOW_UNVERIFIED_STOREKIT_JWS = os.getenv("ALLOW_UNVERIFIED_STOREKIT_JWS", "true").lower() in {"1", "true", "yes"}
ALLOW_DEV_CREDIT = os.getenv("ALLOW_DEV_CREDIT", "").lower() in {"1", "true", "yes"}
FALLBACK_AUDIO_TOKENS_PER_SECOND = float(os.getenv("FALLBACK_AUDIO_TOKENS_PER_SECOND", "50"))
COST_MARKUP_BPS = int(os.getenv("COST_MARKUP_BPS", "0"))
MAX_AUDIO_BYTES = int(os.getenv("MAX_AUDIO_BYTES", str(24 * 1024 * 1024)))

USD_MICROS = 1_000_000


DEFAULT_PRODUCTS = [
    {
        "id": "com.kyleqi.voicetype.credits.small",
        "display_name": "$5 credit",
        "credit_usd_micros": 5 * USD_MICROS,
        "subtitle": "Good for light dictation",
    },
    {
        "id": "com.kyleqi.voicetype.credits.medium",
        "display_name": "$15 credit",
        "credit_usd_micros": 15 * USD_MICROS,
        "subtitle": "Best for everyday typing",
    },
    {
        "id": "com.kyleqi.voicetype.credits.large",
        "display_name": "$50 credit",
        "credit_usd_micros": 50 * USD_MICROS,
        "subtitle": "For heavy usage",
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


app = FastAPI(title="VoiceType API", version="0.1.0")
apple_jwks = PyJWKClient(APPLE_JWKS_URL)


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
    formatted: str


class AuthResponse(BaseModel):
    token: str
    user: AuthUser
    balance: BalancePayload


class CreditProduct(BaseModel):
    id: str
    display_name: str
    credit_usd_micros: int
    subtitle: str


class StoreKitTransactionRequest(BaseModel):
    signed_transaction: str = Field(min_length=16)


class PurchaseCreditResponse(BaseModel):
    balance: BalancePayload
    granted_usd_micros: int
    already_processed: bool


class DevCreditRequest(BaseModel):
    amount_usd_micros: int = Field(gt=0, le=100 * USD_MICROS)


class ChargePayload(BaseModel):
    cost_usd_micros: int
    formatted: str
    pricing_basis: str


class TranscriptionResponse(BaseModel):
    id: str
    transcript: str
    model: str
    charge: ChargePayload
    balance: BalancePayload


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def money(micros: int) -> str:
    return f"${micros / USD_MICROS:,.4f}"


def product_catalog() -> list[dict[str, Any]]:
    raw = os.getenv("CREDIT_PRODUCTS_JSON", "")
    if raw:
        parsed = json.loads(raw)
        if not isinstance(parsed, list):
            raise RuntimeError("CREDIT_PRODUCTS_JSON must be a JSON list.")
        return parsed
    return DEFAULT_PRODUCTS


def product_by_id(product_id: str) -> dict[str, Any]:
    for product in product_catalog():
        if product["id"] == product_id:
            return product
    raise HTTPException(status_code=400, detail=f"Unknown product id: {product_id}")


@contextmanager
def db() -> Any:
    conn = sqlite3.connect(DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    with db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                apple_sub TEXT NOT NULL UNIQUE,
                email TEXT,
                full_name TEXT,
                created_at TEXT NOT NULL
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
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS transcriptions (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
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


@app.on_event("startup")
def on_startup() -> None:
    init_db()


def require_jwt_secret() -> None:
    if not JWT_SECRET:
        raise HTTPException(status_code=500, detail="JWT_SECRET is not configured.")


def require_openai_key() -> None:
    if not OPENAI_API_KEY:
        raise HTTPException(status_code=500, detail="OPENAI_API_KEY is not configured.")


def create_token(user: sqlite3.Row) -> str:
    require_jwt_secret()
    now = datetime.now(timezone.utc)
    payload = {
        "iss": JWT_ISSUER,
        "sub": user["id"],
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(days=JWT_TTL_DAYS)).timestamp()),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")


def current_user(authorization: Annotated[Optional[str], Header()] = None) -> sqlite3.Row:
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
        user = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    if not user:
        raise HTTPException(status_code=401, detail="User no longer exists.")
    return user


def balance_for_user(conn: sqlite3.Connection, user_id: str) -> int:
    row = conn.execute(
        "SELECT COALESCE(SUM(amount_usd_micros), 0) AS balance FROM credit_ledger WHERE user_id = ?",
        (user_id,),
    ).fetchone()
    return int(row["balance"] if row else 0)


def balance_payload(balance: int) -> BalancePayload:
    return BalancePayload(balance_usd_micros=balance, formatted=money(balance))


def insert_ledger(
    conn: sqlite3.Connection,
    *,
    user_id: str,
    amount_usd_micros: int,
    kind: str,
    description: str,
    source_id: Optional[str] = None,
) -> None:
    conn.execute(
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


def upsert_apple_user(payload: dict[str, Any], request: AppleAuthRequest) -> sqlite3.Row:
    apple_sub = str(payload.get("sub") or "").strip()
    if not apple_sub:
        raise HTTPException(status_code=401, detail="Apple identity token is missing sub.")

    email = request.email or payload.get("email")
    full_name = request.full_name

    with db() as conn:
        user = conn.execute("SELECT * FROM users WHERE apple_sub = ?", (apple_sub,)).fetchone()
        if user:
            conn.execute(
                "UPDATE users SET email = COALESCE(?, email), full_name = COALESCE(?, full_name) WHERE id = ?",
                (email, full_name, user["id"]),
            )
            return conn.execute("SELECT * FROM users WHERE id = ?", (user["id"],)).fetchone()

        user_id = str(uuid.uuid4())
        conn.execute(
            "INSERT INTO users (id, apple_sub, email, full_name, created_at) VALUES (?, ?, ?, ?, ?)",
            (user_id, apple_sub, email, full_name, utc_now()),
        )
        return conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()


def decode_storekit_payload(jws: str) -> dict[str, Any]:
    if not ALLOW_UNVERIFIED_STOREKIT_JWS:
        raise HTTPException(
            status_code=501,
            detail="StoreKit signature verification is required before production purchases are accepted.",
        )
    parts = jws.split(".")
    if len(parts) != 3:
        raise HTTPException(status_code=400, detail="StoreKit transaction must be a compact JWS.")
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(payload.encode("utf-8")))
    except (ValueError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=400, detail="Invalid StoreKit transaction payload.") from exc


def resolve_model(model: Optional[str]) -> str:
    selected = (model or OPENAI_TRANSCRIBE_MODEL).strip()
    if selected not in MODEL_PRICING:
        raise HTTPException(status_code=400, detail=f"Unsupported transcription model: {selected}")
    return selected


def extract_usage(payload: dict[str, Any]) -> tuple[Optional[int], Optional[int]]:
    usage = payload.get("usage") or {}
    input_tokens = (
        usage.get("input_tokens")
        or usage.get("audio_tokens")
        or usage.get("prompt_tokens")
        or usage.get("total_input_tokens")
    )
    output_tokens = usage.get("output_tokens") or usage.get("completion_tokens") or usage.get("total_output_tokens")
    return (int(input_tokens) if input_tokens else None, int(output_tokens) if output_tokens else None)


def estimate_text_tokens(text: str) -> int:
    return max(1, math.ceil(len(text) / 4))


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
        cost = math.ceil(minutes * pricing["per_minute_usd_micros"])
        basis = "duration"
        charged_input = math.ceil(minutes * 60)
        charged_output = 0
    else:
        charged_input = input_tokens or math.ceil(max(audio_seconds, 1.0) * FALLBACK_AUDIO_TOKENS_PER_SECOND)
        charged_output = output_tokens or estimate_text_tokens(transcript)
        input_cost = charged_input * pricing["input_per_million_usd_micros"] / 1_000_000
        output_cost = charged_output * pricing["output_per_million_usd_micros"] / 1_000_000
        cost = math.ceil(input_cost + output_cost)
        basis = "reported_usage" if input_tokens or output_tokens else "duration_estimate"

    if COST_MARKUP_BPS:
        cost = math.ceil(cost * (10_000 + COST_MARKUP_BPS) / 10_000)
    return max(cost, 1), basis, charged_input, charged_output


def estimate_preflight_cost(model: str, audio_seconds: float) -> int:
    cost, _, _, _ = calculate_cost(
        model=model,
        audio_seconds=max(audio_seconds, 1.0),
        transcript="",
        input_tokens=None,
        output_tokens=1,
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
        response = await client.post(
            f"{OPENAI_BASE_URL}/v1/audio/transcriptions",
            headers=headers,
            data=data,
            files=files,
        )

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
        "storekit_dev_mode": ALLOW_UNVERIFIED_STOREKIT_JWS,
    }


@app.post("/v1/auth/apple", response_model=AuthResponse)
def auth_apple(request: AppleAuthRequest) -> AuthResponse:
    apple_payload = verify_apple_identity_token(request.identity_token)
    user = upsert_apple_user(apple_payload, request)
    with db() as conn:
        balance = balance_for_user(conn, user["id"])
    return AuthResponse(
        token=create_token(user),
        user=AuthUser(id=user["id"], email=user["email"]),
        balance=balance_payload(balance),
    )


@app.get("/v1/me")
def me(user: Annotated[sqlite3.Row, Depends(current_user)]) -> dict[str, Any]:
    with db() as conn:
        balance = balance_for_user(conn, user["id"])
    return {"user": AuthUser(id=user["id"], email=user["email"]), "balance": balance_payload(balance)}


@app.get("/v1/billing/products")
def products() -> dict[str, list[CreditProduct]]:
    return {"products": [CreditProduct(**product) for product in product_catalog()]}


@app.post("/v1/billing/storekit/transactions", response_model=PurchaseCreditResponse)
def storekit_transaction(
    request: StoreKitTransactionRequest,
    user: Annotated[sqlite3.Row, Depends(current_user)],
) -> PurchaseCreditResponse:
    payload = decode_storekit_payload(request.signed_transaction)
    product_id = str(payload.get("productId") or payload.get("product_id") or "")
    transaction_id = str(payload.get("transactionId") or payload.get("transaction_id") or "")
    bundle_id = payload.get("bundleId") or payload.get("bundle_id")
    environment = payload.get("environment")

    if not transaction_id:
        raise HTTPException(status_code=400, detail="StoreKit transaction is missing transactionId.")
    if bundle_id and bundle_id != APPLE_CLIENT_ID:
        raise HTTPException(status_code=400, detail="StoreKit transaction bundle id does not match this app.")

    product = product_by_id(product_id)
    credit = int(product["credit_usd_micros"])

    with db() as conn:
        existing = conn.execute(
            "SELECT transaction_id FROM storekit_transactions WHERE transaction_id = ?",
            (transaction_id,),
        ).fetchone()
        if existing:
            return PurchaseCreditResponse(
                balance=balance_payload(balance_for_user(conn, user["id"])),
                granted_usd_micros=0,
                already_processed=True,
            )

        conn.execute(
            """
            INSERT INTO storekit_transactions
                (transaction_id, user_id, product_id, signed_transaction, environment, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (transaction_id, user["id"], product_id, request.signed_transaction, environment, utc_now()),
        )
        insert_ledger(
            conn,
            user_id=user["id"],
            amount_usd_micros=credit,
            kind="storekit_purchase",
            description=f"Credit pack: {product['display_name']}",
            source_id=transaction_id,
        )
        balance = balance_for_user(conn, user["id"])

    return PurchaseCreditResponse(
        balance=balance_payload(balance),
        granted_usd_micros=credit,
        already_processed=False,
    )


@app.post("/v1/billing/dev-credit", response_model=PurchaseCreditResponse)
def grant_dev_credit(
    request: DevCreditRequest,
    user: Annotated[sqlite3.Row, Depends(current_user)],
) -> PurchaseCreditResponse:
    if not ALLOW_DEV_CREDIT:
        raise HTTPException(status_code=404, detail="Dev credit is disabled.")
    with db() as conn:
        insert_ledger(
            conn,
            user_id=user["id"],
            amount_usd_micros=request.amount_usd_micros,
            kind="dev_credit",
            description="Local development credit",
            source_id=f"dev-{uuid.uuid4()}",
        )
        balance = balance_for_user(conn, user["id"])
    return PurchaseCreditResponse(
        balance=balance_payload(balance),
        granted_usd_micros=request.amount_usd_micros,
        already_processed=False,
    )


@app.post("/v1/transcriptions", response_model=TranscriptionResponse)
async def create_transcription(
    user: Annotated[sqlite3.Row, Depends(current_user)],
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
        balance = balance_for_user(conn, user["id"])
        if balance <= 0:
            raise HTTPException(status_code=402, detail="Add credit before transcribing.")
        if balance < preflight_cost:
            raise HTTPException(status_code=402, detail=f"Insufficient credit. Need at least {money(preflight_cost)}.")

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
        conn.execute(
            """
            INSERT INTO transcriptions
                (id, user_id, model, audio_seconds, transcript, input_tokens, output_tokens,
                 cost_usd_micros, pricing_basis, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                transcription_id,
                user["id"],
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
            source_id=transcription_id,
        )
        balance = balance_for_user(conn, user["id"])

    return JSONResponse(
        TranscriptionResponse(
            id=transcription_id,
            transcript=transcript,
            model=selected_model,
            charge=ChargePayload(cost_usd_micros=cost, formatted=money(cost), pricing_basis=pricing_basis),
            balance=balance_payload(balance),
        ).model_dump()
    )
