import base64
import importlib
import json
import sys
from pathlib import Path

from fastapi import HTTPException
from fastapi.testclient import TestClient

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))


def b64url(payload: dict) -> str:
    raw = json.dumps(payload, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def fake_jws(payload: dict) -> str:
    return f"{b64url({'alg': 'none'})}.{b64url(payload)}.sig"


def load_main(tmp_path, monkeypatch):
    monkeypatch.setenv("JWT_SECRET", "test-secret")
    monkeypatch.setenv("APPLE_AUTH_DEV_BYPASS", "true")
    monkeypatch.setenv("ALLOW_DEV_CREDIT", "true")
    monkeypatch.setenv("STOREKIT_VERIFICATION_MODE", "development")
    monkeypatch.setenv("ALLOW_UNVERIFIED_STOREKIT_JWS", "true")
    # Disable the welcome credit so balance assertions below stay exact; the
    # signup grant has its own dedicated tests.
    monkeypatch.setenv("SIGNUP_GRANT_ENABLED", "false")
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "voicetype.sqlite3"))
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("COST_MARKUP_BPS", raising=False)

    if "main" in sys.modules:
        del sys.modules["main"]
    return importlib.import_module("main")


def load_production_main(tmp_path, monkeypatch):
    monkeypatch.setenv("JWT_SECRET", "test-secret")
    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.setenv("APPLE_APP_APPLE_ID", "1234567890")
    monkeypatch.setenv("APPLE_ROOT_CERTIFICATE_PEMS_B64", base64.b64encode(b"cert").decode())
    monkeypatch.setenv("STOREKIT_VERIFICATION_MODE", "strict")
    monkeypatch.setenv("ALLOW_UNVERIFIED_STOREKIT_JWS", "false")
    monkeypatch.setenv("REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN", "true")
    monkeypatch.setenv("ALLOW_DEV_CREDIT", "false")
    monkeypatch.setenv("SIGNUP_GRANT_ENABLED", "false")
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "voicetype.sqlite3"))
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("COST_MARKUP_BPS", raising=False)
    monkeypatch.delenv("APPLE_AUTH_DEV_BYPASS", raising=False)

    if "main" in sys.modules:
        del sys.modules["main"]
    return importlib.import_module("main")


def auth(client: TestClient, name: str) -> dict:
    response = client.post(
        "/v1/auth/apple",
        json={"identity_token": f"dev:{name}", "email": f"{name}@example.dev"},
    )
    assert response.status_code == 200, response.text
    payload = response.json()
    return {
        "payload": payload,
        "headers": {"Authorization": f"Bearer {payload['token']}"},
    }


def test_per_user_ledger_and_storekit_replay_protection(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        bob = auth(client, "bob")

        dev_credit = client.post(
            "/v1/billing/dev-credit",
            headers=alice["headers"],
            json={"amount_usd_micros": 1_000_000},
        )
        assert dev_credit.status_code == 200, dev_credit.text
        assert dev_credit.json()["balance"]["balance_usd_micros"] == 1_000_000
        assert dev_credit.json()["balance"]["balance_credit_units"] == 1_000_000
        assert dev_credit.json()["balance"]["formatted"] == "1,000,000 credits"

        transaction = fake_jws(
            {
                "productId": "com.kyleqi.voicetype.credits.small",
                "transactionId": "tx-smoke-1",
                "originalTransactionId": "tx-smoke-1",
                "bundleId": "com.kyleqi.voicetype",
                "environment": "LocalTesting",
                "appAccountToken": alice["payload"]["user"]["id"],
            }
        )

        purchase = client.post(
            "/v1/billing/storekit/transactions",
            headers=alice["headers"],
            json={"signed_transaction": transaction},
        )
        assert purchase.status_code == 200, purchase.text
        assert purchase.json()["granted_usd_micros"] == 990_000
        assert purchase.json()["granted_credit_units"] == 990_000
        assert purchase.json()["balance"]["balance_usd_micros"] == 1_990_000
        assert purchase.json()["balance"]["balance_credit_units"] == 1_990_000

        duplicate = client.post(
            "/v1/billing/storekit/transactions",
            headers=alice["headers"],
            json={"signed_transaction": transaction},
        )
        assert duplicate.status_code == 200, duplicate.text
        assert duplicate.json()["already_processed"] is True
        assert duplicate.json()["granted_credit_units"] == 0
        assert duplicate.json()["balance"]["balance_usd_micros"] == 1_990_000

        cross_user = client.post(
            "/v1/billing/storekit/transactions",
            headers=bob["headers"],
            json={"signed_transaction": transaction},
        )
        assert cross_user.status_code == 403, cross_user.text

        bob_me = client.get("/v1/me", headers=bob["headers"])
        assert bob_me.status_code == 200, bob_me.text
        assert bob_me.json()["balance"]["balance_usd_micros"] == 0


def test_product_catalog_uses_paid_price_credit_units(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    with TestClient(main.app) as client:
        response = client.get("/v1/billing/products")

    assert response.status_code == 200, response.text
    products = {product["id"]: product for product in response.json()["products"]}

    small = products["com.kyleqi.voicetype.credits.small"]
    medium = products["com.kyleqi.voicetype.credits.medium"]
    large = products["com.kyleqi.voicetype.credits.large"]

    assert small["display_name"] == "990,000 credits"
    assert small["credit_usd_micros"] == 990_000
    assert small["credit_units"] == 990_000
    assert medium["credit_units"] == 4_990_000
    assert large["credit_units"] == 19_990_000


def test_storekit_requires_app_account_token(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    with TestClient(main.app) as client:
        user = auth(client, "alice")
        transaction = fake_jws(
            {
                "productId": "com.kyleqi.voicetype.credits.small",
                "transactionId": "tx-no-account-token",
                "bundleId": "com.kyleqi.voicetype",
            }
        )

        response = client.post(
            "/v1/billing/storekit/transactions",
            headers=user["headers"],
            json={"signed_transaction": transaction},
        )
        assert response.status_code == 400, response.text


def test_dev_credit_can_require_shared_secret(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.DEV_CREDIT_SHARED_SECRET = "test-secret"
    main.DEV_CREDIT_MAX_USD_MICROS = 2_000_000

    with TestClient(main.app) as client:
        user = auth(client, "alice")

        missing_secret = client.post(
            "/v1/billing/dev-credit",
            headers=user["headers"],
            json={"amount_usd_micros": 1_000_000},
        )
        assert missing_secret.status_code == 404, missing_secret.text

        wrong_secret = client.post(
            "/v1/billing/dev-credit",
            headers={**user["headers"], "X-VoiceType-Dev-Credit-Key": "wrong"},
            json={"amount_usd_micros": 1_000_000},
        )
        assert wrong_secret.status_code == 404, wrong_secret.text

        too_much = client.post(
            "/v1/billing/dev-credit",
            headers={**user["headers"], "X-VoiceType-Dev-Credit-Key": "test-secret"},
            json={"amount_usd_micros": 3_000_000},
        )
        assert too_much.status_code == 400, too_much.text

        granted = client.post(
            "/v1/billing/dev-credit",
            headers={**user["headers"], "X-VoiceType-Dev-Credit-Key": "test-secret"},
            json={"amount_usd_micros": 2_000_000},
        )
        assert granted.status_code == 200, granted.text
        assert granted.json()["granted_usd_micros"] == 2_000_000
        assert granted.json()["granted_credit_units"] == 2_000_000


def test_default_retail_markup_covers_app_store_commission_and_profit(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    assert main.DEFAULT_COST_MARKUP_BPS == 7143

    cost, basis, charged_input, charged_output = main.calculate_cost(
        model="gpt-4o-mini-transcribe",
        audio_seconds=1,
        transcript="hello",
        input_tokens=1_000,
        output_tokens=100,
    )

    assert basis == "reported_usage"
    assert charged_input == 1_000
    assert charged_output == 100
    assert cost == 3_001


def test_audio_minute_pricing_uses_retail_markup(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    cost, basis, charged_input, charged_output = main.calculate_cost(
        model="whisper-1",
        audio_seconds=60,
        transcript="hello",
        input_tokens=None,
        output_tokens=None,
    )

    assert basis == "duration"
    assert charged_input == 60
    assert charged_output == 0
    assert cost == 10_286


def test_transcription_debits_user_after_successful_provider_response(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    async def fake_transcribe_audio(*args, **kwargs):
        return {"text": "hello world", "usage": {"input_tokens": 1_000, "output_tokens": 100}}

    monkeypatch.setattr(main, "transcribe_audio", fake_transcribe_audio)

    with TestClient(main.app) as client:
        user = auth(client, "alice")
        credit = client.post(
            "/v1/billing/dev-credit",
            headers=user["headers"],
            json={"amount_usd_micros": 1_000_000},
        )
        assert credit.status_code == 200, credit.text

        response = client.post(
            "/v1/transcriptions",
            headers=user["headers"],
            data={"audio_seconds": "1.0"},
            files={"file": ("clip.m4a", b"fake audio", "audio/m4a")},
        )

    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["transcript"] == "hello world"
    assert payload["charge"]["cost_usd_micros"] == 3_001
    assert payload["balance"]["balance_usd_micros"] == 996_999


def test_transcription_reservation_blocks_second_provider_call_when_credit_is_held(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.MIN_TRANSCRIPTION_RESERVATION_USD_MICROS = 20_000
    calls = 0

    async def fake_transcribe_audio(*args, **kwargs):
        nonlocal calls
        calls += 1
        return {"text": "hello world", "usage": {"input_tokens": 1_000, "output_tokens": 100}}

    monkeypatch.setattr(main, "transcribe_audio", fake_transcribe_audio)

    with TestClient(main.app) as client:
        user = auth(client, "alice")
        credit = client.post(
            "/v1/billing/dev-credit",
            headers=user["headers"],
            json={"amount_usd_micros": 20_000},
        )
        assert credit.status_code == 200, credit.text

        first = client.post(
            "/v1/transcriptions",
            headers=user["headers"],
            data={"audio_seconds": "1.0"},
            files={"file": ("clip.m4a", b"fake audio", "audio/m4a")},
        )
        second = client.post(
            "/v1/transcriptions",
            headers=user["headers"],
            data={"audio_seconds": "1.0"},
            files={"file": ("clip.m4a", b"fake audio", "audio/m4a")},
        )

    assert first.status_code == 200, first.text
    assert first.json()["charge"]["cost_usd_micros"] == 3_001
    assert first.json()["balance"]["balance_usd_micros"] == 16_999
    assert second.status_code == 402, second.text
    assert calls == 1


def test_transcription_provider_failure_does_not_debit_user(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    async def fake_transcribe_audio(*args, **kwargs):
        raise HTTPException(status_code=502, detail="provider unavailable")

    monkeypatch.setattr(main, "transcribe_audio", fake_transcribe_audio)

    with TestClient(main.app) as client:
        user = auth(client, "alice")
        credit = client.post(
            "/v1/billing/dev-credit",
            headers=user["headers"],
            json={"amount_usd_micros": 1_000_000},
        )
        assert credit.status_code == 200, credit.text

        failed = client.post(
            "/v1/transcriptions",
            headers=user["headers"],
            data={"audio_seconds": "1.0"},
            files={"file": ("clip.m4a", b"fake audio", "audio/m4a")},
        )
        balance = client.get("/v1/me", headers=user["headers"])

    assert failed.status_code == 502, failed.text
    assert balance.status_code == 200, balance.text
    assert balance.json()["balance"]["balance_usd_micros"] == 1_000_000


def test_auth_rate_limit_returns_429(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.AUTH_RATE_LIMIT_PER_WINDOW = 1
    main._rate_limit_hits.clear()

    with TestClient(main.app) as client:
        first = client.post(
            "/v1/auth/apple",
            json={"identity_token": "dev:alice", "email": "alice@example.dev"},
        )
        second = client.post(
            "/v1/auth/apple",
            json={"identity_token": "dev:bob", "email": "bob@example.dev"},
        )

    assert first.status_code == 200, first.text
    assert second.status_code == 429, second.text
    assert second.headers["Retry-After"]


def test_auth_rate_limit_uses_forwarded_client_ip_from_trusted_proxy(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.AUTH_RATE_LIMIT_PER_WINDOW = 1
    main._trusted_proxy_networks = [main.ipaddress.ip_network("172.16.0.0/12")]
    main._rate_limit_hits.clear()

    with TestClient(main.app, client=("172.18.0.5", 49152)) as client:
        first = client.post(
            "/v1/auth/apple",
            headers={"X-Forwarded-For": "198.51.100.1, 203.0.113.10"},
            json={"identity_token": "dev:alice", "email": "alice@example.dev"},
        )
        second = client.post(
            "/v1/auth/apple",
            headers={"X-Forwarded-For": "198.51.100.1, 203.0.113.11"},
            json={"identity_token": "dev:bob", "email": "bob@example.dev"},
        )
        third = client.post(
            "/v1/auth/apple",
            headers={"X-Forwarded-For": "198.51.100.99, 203.0.113.10"},
            json={"identity_token": "dev:carol", "email": "carol@example.dev"},
        )

    assert first.status_code == 200, first.text
    assert second.status_code == 200, second.text
    assert third.status_code == 429, third.text


def test_auth_rate_limit_ignores_spoofed_forwarded_ip_from_untrusted_client(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.AUTH_RATE_LIMIT_PER_WINDOW = 1
    main._trusted_proxy_networks = [main.ipaddress.ip_network("172.16.0.0/12")]
    main._rate_limit_hits.clear()

    with TestClient(main.app, client=("198.51.100.200", 49152)) as client:
        first = client.post(
            "/v1/auth/apple",
            headers={"X-Forwarded-For": "203.0.113.10"},
            json={"identity_token": "dev:alice", "email": "alice@example.dev"},
        )
        second = client.post(
            "/v1/auth/apple",
            headers={"X-Forwarded-For": "203.0.113.11"},
            json={"identity_token": "dev:bob", "email": "bob@example.dev"},
        )

    assert first.status_code == 200, first.text
    assert second.status_code == 429, second.text


def test_readiness_reports_development_configuration_as_not_ready(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    with TestClient(main.app) as client:
        response = client.get("/health/ready")

    assert response.status_code == 503, response.text
    checks = response.json()["checks"]
    assert checks["database"] is True
    assert checks["dev_credit_disabled"] is False
    assert checks["storekit_strict"] is False


def test_readiness_accepts_production_configuration(tmp_path, monkeypatch):
    main = load_production_main(tmp_path, monkeypatch)

    with TestClient(main.app) as client:
        response = client.get("/health/ready")

    assert response.status_code == 200, response.text
    assert response.json()["ok"] is True


def test_privacy_policy_is_public(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    with TestClient(main.app) as client:
        response = client.get("/privacy")

    assert response.status_code == 200, response.text
    assert "text/html" in response.headers["content-type"]
    assert "VoiceType Privacy Policy" in response.text
    assert "kq@apeonwheels.com" in response.text
    assert "We do not track you across other apps or websites." in response.text

    with TestClient(main.app) as client:
        head_response = client.head("/privacy")

    assert head_response.status_code == 200
    assert "text/html" in head_response.headers["content-type"]


def test_signup_grant_is_applied_once_on_account_creation(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    # The helper disables the grant for exact-balance tests; enable it here.
    main.SIGNUP_GRANT_ENABLED = True
    main.SIGNUP_GRANT_USD_MICROS = 100_000

    with TestClient(main.app) as client:
        first = auth(client, "alice")
        assert first["payload"]["balance"]["balance_usd_micros"] == 100_000

        # Signing in again must not grant the welcome credit a second time.
        second = auth(client, "alice")
        assert second["payload"]["balance"]["balance_usd_micros"] == 100_000

        me = client.get("/v1/me", headers=second["headers"])
        assert me.status_code == 200, me.text
        assert me.json()["balance"]["balance_usd_micros"] == 100_000


def test_signup_grant_backfills_on_next_sign_in(tmp_path, monkeypatch):
    # If the grant was never written (failed grant, crash after account
    # creation, or the account predates the feature), the next sign-in
    # self-heals by applying it exactly once.
    main = load_main(tmp_path, monkeypatch)

    with TestClient(main.app) as client:
        first = auth(client, "alice")
        assert first["payload"]["balance"]["balance_usd_micros"] == 0

        main.SIGNUP_GRANT_ENABLED = True
        main.SIGNUP_GRANT_USD_MICROS = 100_000

        second = auth(client, "alice")
        assert second["payload"]["user"]["id"] == first["payload"]["user"]["id"]
        assert second["payload"]["balance"]["balance_usd_micros"] == 100_000

        third = auth(client, "alice")
        assert third["payload"]["balance"]["balance_usd_micros"] == 100_000


def test_account_deletion_removes_user_and_cascades_credit(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        original_id = alice["payload"]["user"]["id"]

        credit = client.post(
            "/v1/billing/dev-credit",
            headers=alice["headers"],
            json={"amount_usd_micros": 1_000_000},
        )
        assert credit.status_code == 200, credit.text
        assert credit.json()["balance"]["balance_usd_micros"] == 1_000_000

        deleted = client.delete("/v1/account", headers=alice["headers"])
        assert deleted.status_code == 200, deleted.text
        assert deleted.json()["ok"] is True
        # No Sign in with Apple server credentials are configured in tests, so the
        # token cannot be revoked, but deletion still succeeds.
        assert deleted.json()["apple_token_revoked"] is False

        # The old session token is now invalid because the user row is gone.
        after = client.get("/v1/me", headers=alice["headers"])
        assert after.status_code == 401, after.text

        # Re-signing in creates a brand new user (new id) with no leftover credit,
        # proving the prior ledger rows were removed by ON DELETE CASCADE.
        again = auth(client, "alice")
        assert again["payload"]["user"]["id"] != original_id
        assert again["payload"]["balance"]["balance_usd_micros"] == 0


def test_account_deletion_requires_authentication(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)

    with TestClient(main.app) as client:
        response = client.delete("/v1/account")
        assert response.status_code == 401, response.text
