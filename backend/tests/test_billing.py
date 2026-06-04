import base64
import importlib
import json
import sys

from fastapi.testclient import TestClient


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
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "voicetype.sqlite3"))
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("COST_MARKUP_BPS", raising=False)

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
        assert purchase.json()["granted_usd_micros"] == 1_000_000
        assert purchase.json()["balance"]["balance_usd_micros"] == 2_000_000

        duplicate = client.post(
            "/v1/billing/storekit/transactions",
            headers=alice["headers"],
            json={"signed_transaction": transaction},
        )
        assert duplicate.status_code == 200, duplicate.text
        assert duplicate.json()["already_processed"] is True
        assert duplicate.json()["balance"]["balance_usd_micros"] == 2_000_000

        cross_user = client.post(
            "/v1/billing/storekit/transactions",
            headers=bob["headers"],
            json={"signed_transaction": transaction},
        )
        assert cross_user.status_code == 403, cross_user.text

        bob_me = client.get("/v1/me", headers=bob["headers"])
        assert bob_me.status_code == 200, bob_me.text
        assert bob_me.json()["balance"]["balance_usd_micros"] == 0


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
