"""Refund lifecycle tests after signature verification, plus fail-closed webhook checks."""

from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from test_billing import auth, fake_jws, load_main, load_production_main
from test_reliability import transcribe


def purchase_payload(main, user, transaction_id="refund-tx"):
    return {
        "productId": "com.kyleqi.voicetype.credits.small", "transactionId": transaction_id,
        "bundleId": main.APPLE_BUNDLE_ID, "environment": "LocalTesting",
        "appAccountToken": user["payload"]["user"]["id"], "type": "Consumable", "quantity": 1,
    }


def deliver_purchase(client, user, payload):
    return client.post("/v1/billing/storekit/transactions", headers=user["headers"],
        json={"signed_transaction": fake_jws(payload)})


def verified_event(main, monkeypatch, payload, *, kind="REFUND", signed_date=1000, notification_id=None):
    transaction = {**payload}
    if kind == "REFUND":
        transaction["revocationDate"] = signed_date
    event = {
        "notification_id": notification_id or f"event-{kind}-{signed_date}",
        "notification_type": kind, "signed_date": signed_date,
        "environment": "LocalTesting", "signed_transaction": fake_jws(transaction),
    }
    # This seam simulates already Apple-verified input. Production has no
    # unsigned-notification path; rejection/configuration tests below cover it.
    monkeypatch.setattr(main, "verify_storekit_notification", lambda signed: event)
    return event


def notify(client):
    return client.post("/v1/billing/storekit/notifications", json={"signedPayload": "verified-by-test-seam"})


def balance(client, user):
    return client.get("/v1/me", headers=user["headers"]).json()["balance"]["balance_usd_micros"]


def test_refund_and_reversal_are_idempotent_and_ordered(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = purchase_payload(main, user)
        assert deliver_purchase(client, user, payload).status_code == 200
        verified_event(main, monkeypatch, payload)
        assert notify(client).status_code == 200
        assert notify(client).json()["already_processed"]
        assert balance(client, user) == 0
        verified_event(main, monkeypatch, payload, kind="REFUND_REVERSED", signed_date=2000)
        assert notify(client).status_code == 200
        assert notify(client).json()["already_processed"]
        assert balance(client, user) == 990_000
        verified_event(main, monkeypatch, payload, signed_date=1500)
        assert notify(client).json()["ignored"]
        assert balance(client, user) == 990_000
        # A newer second refund is a fresh state transition, not a replay.
        verified_event(main, monkeypatch, payload, signed_date=3000)
        assert notify(client).status_code == 200
        assert balance(client, user) == 0
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM credit_ledger WHERE kind = 'storekit_refund'").fetchone()[0] == 2


def test_consumed_refund_can_go_negative_and_blocks_new_provider_spend(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = purchase_payload(main, user)
        deliver_purchase(client, user, payload)
        with main.db() as conn:
            main.insert_ledger(conn, user_id=user["payload"]["user"]["id"], amount_usd_micros=-100_000,
                kind="transcription", description="previous consumption", source_id="test-spend")
        verified_event(main, monkeypatch, payload)
        assert notify(client).status_code == 200
        assert balance(client, user) == -100_000
        assert transcribe(client, user).status_code == 402


def test_refund_uses_original_grant_even_if_catalog_credit_changes(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = purchase_payload(main, user)
        deliver_purchase(client, user, payload)
        monkeypatch.setattr(main, "product_catalog", lambda: [])
        verified_event(main, monkeypatch, payload)
        assert notify(client).status_code == 200
        assert balance(client, user) == 0


def test_refund_before_client_delivery_blocks_old_signed_purchase(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = purchase_payload(main, user)
        verified_event(main, monkeypatch, payload)
        assert notify(client).status_code == 200
        assert balance(client, user) == 0
        assert deliver_purchase(client, user, payload).status_code == 400
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM credit_ledger").fetchone()[0] == 0


def test_reversal_before_client_delivery_allows_exactly_one_first_grant(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = purchase_payload(main, user)
        verified_event(main, monkeypatch, payload)
        notify(client)
        verified_event(main, monkeypatch, payload, kind="REFUND_REVERSED", signed_date=2000)
        assert notify(client).status_code == 200
        assert balance(client, user) == 0
        assert deliver_purchase(client, user, payload).status_code == 200
        assert deliver_purchase(client, user, payload).json()["already_processed"]
        assert balance(client, user) == 990_000


def test_reversal_arriving_before_older_refund_does_not_add_credit(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = purchase_payload(main, user)
        deliver_purchase(client, user, payload)
        verified_event(main, monkeypatch, payload, kind="REFUND_REVERSED", signed_date=2000)
        assert notify(client).status_code == 200
        assert balance(client, user) == 990_000
        verified_event(main, monkeypatch, payload)
        assert notify(client).json()["ignored"]
        assert balance(client, user) == 990_000


def test_concurrent_duplicate_refund_debits_once(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = purchase_payload(main, user)
        deliver_purchase(client, user, payload)
        verified_event(main, monkeypatch, payload)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: notify(client), range(2)))
        assert all(result.status_code == 200 for result in results)
        assert balance(client, user) == 0
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM credit_ledger WHERE kind = 'storekit_refund'").fetchone()[0] == 1


def test_deleted_or_unknown_account_notifications_never_create_credit(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        payload = purchase_payload(main, user)
        deliver_purchase(client, user, payload)
        verified_event(main, monkeypatch, payload)
        notify(client)
        assert client.delete("/v1/account", headers=user["headers"]).status_code == 200
        verified_event(main, monkeypatch, payload, kind="REFUND_REVERSED", signed_date=2000)
        assert notify(client).json()["ignored"]
        with main.db() as conn:
            for table in ("credit_ledger", "storekit_transactions", "storekit_refund_states", "storekit_notification_events"):
                assert conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0


def test_wrong_account_signed_refund_cannot_change_purchase_owner(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        alice, bob = auth(client, "alice"), auth(client, "bob")
        payload = purchase_payload(main, alice)
        deliver_purchase(client, alice, payload)
        payload["appAccountToken"] = bob["payload"]["user"]["id"]
        verified_event(main, monkeypatch, payload)
        assert notify(client).status_code == 400
        assert balance(client, alice) == 990_000
        assert balance(client, bob) == 0


def test_refund_ledger_failure_rolls_back_state_and_allows_retry(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app, raise_server_exceptions=False) as client:
        user = auth(client, "alice")
        payload = purchase_payload(main, user)
        deliver_purchase(client, user, payload)
        verified_event(main, monkeypatch, payload)
        original = main.insert_ledger
        def fail(*args, **kwargs):
            raise RuntimeError("injected accounting failure")
        monkeypatch.setattr(main, "insert_ledger", fail)
        assert notify(client).status_code == 500
        assert balance(client, user) == 990_000
        with main.db() as conn:
            assert conn.execute("SELECT COUNT(*) FROM storekit_refund_states").fetchone()[0] == 0
        monkeypatch.setattr(main, "insert_ledger", original)
        assert notify(client).status_code == 200
        assert balance(client, user) == 0


def test_webhook_has_no_unsigned_development_path(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        response = client.post("/v1/billing/storekit/notifications", json={"signedPayload": fake_jws({"notificationType": "REFUND"})})
    assert response.status_code == 503


def test_strict_webhook_rejects_unsigned_notification(tmp_path, monkeypatch):
    main = load_production_main(tmp_path, monkeypatch)
    with pytest.raises(HTTPException) as error:
        main.verify_storekit_notification(fake_jws({"notificationType": "REFUND", "version": "2.0"}))
    assert error.value.status_code == 401


def test_signed_notification_and_nested_transaction_are_both_verified(tmp_path, monkeypatch):
    # A locally generated trusted test chain exercises real ES256 verification.
    # Only certificate OCSP network access is mocked; these are not Apple-issued
    # certificates and this test does not establish live Apple delivery.
    import base64
    import time
    from datetime import datetime, timedelta, timezone
    import jwt
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID, ObjectIdentifier
    from appstoreserverlibrary.signed_data_verifier import _ChainVerifier

    main = load_production_main(tmp_path, monkeypatch)
    main.STOREKIT_ACCEPTED_ENVIRONMENTS = "PRODUCTION"
    keys = [ec.generate_private_key(ec.SECP256R1()) for _ in range(3)]
    names = [x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, label)]) for label in ("QA Root", "QA Intermediate", "QA Signing")]
    now = datetime.now(timezone.utc)
    certificates = []
    for index in range(3):
        issuer = max(0, index - 1)
        certificate = (x509.CertificateBuilder().subject_name(names[index]).issuer_name(names[issuer])
            .public_key(keys[index].public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=1))
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(keys[index].public_key()), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(keys[issuer].public_key()), critical=False)
            .add_extension(x509.BasicConstraints(ca=index < 2, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                key_encipherment=False, data_encipherment=False, key_agreement=False,
                key_cert_sign=index < 2, crl_sign=index < 2, encipher_only=False, decipher_only=False), critical=True))
        if index:
            oid = "1.2.840.113635.100.6.2.1" if index == 1 else "1.2.840.113635.100.6.11.1"
            certificate = certificate.add_extension(x509.UnrecognizedExtension(ObjectIdentifier(oid), b"\x05\x00"), critical=False)
        certificates.append(certificate.sign(keys[issuer], hashes.SHA256()))
    ders = [certificate.public_bytes(serialization.Encoding.DER) for certificate in certificates]
    monkeypatch.setattr(main, "load_apple_root_certificates", lambda: [ders[0]])
    ocsp_checks = []
    monkeypatch.setattr(_ChainVerifier, "check_ocsp_status", lambda *args: ocsp_checks.append(True))
    headers = {"x5c": [base64.b64encode(der).decode() for der in reversed(ders)]}
    def signed(payload):
        return jwt.encode(payload, keys[2], algorithm="ES256", headers=headers)
    with TestClient(main.app) as client:
        account = main.upsert_apple_user({"sub": "qa-signed-apple-user"}, main.AppleAuthRequest(identity_token="unused"))
        user = {"payload": {"user": {"id": account["id"]}}, "headers": {"Authorization": f"Bearer {main.create_token(account)}"}}
        transaction = {**purchase_payload(main, user), "environment": "Production", "signedDate": int(time.time() * 1000)}
        purchase = client.post("/v1/billing/storekit/transactions", headers=user["headers"], json={"signed_transaction": signed(transaction)})
        assert purchase.status_code == 200, purchase.text
        transaction["revocationDate"] = transaction["signedDate"]
        notification = {"notificationType": "REFUND", "notificationUUID": "qa-real-signature", "version": "2.0", "signedDate": transaction["signedDate"],
            "data": {"environment": "Production", "bundleId": main.APPLE_BUNDLE_ID, "appAppleId": int(main.APPLE_APP_APPLE_ID), "signedTransactionInfo": signed(transaction)}}
        accepted = client.post("/v1/billing/storekit/notifications", json={"signedPayload": signed(notification)})
        assert accepted.status_code == 200, accepted.text
        assert balance(client, user) == 0
        notification["data"]["signedTransactionInfo"] = fake_jws(transaction)
        rejected_inner = client.post("/v1/billing/storekit/notifications", json={"signedPayload": signed(notification)})
        assert rejected_inner.status_code == 401
        rejected_outer = client.post("/v1/billing/storekit/notifications", json={"signedPayload": fake_jws(notification)})
        assert rejected_outer.status_code == 401
    assert ocsp_checks
