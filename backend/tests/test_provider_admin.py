import json
import logging
from dataclasses import replace
from html.parser import HTMLParser
from pathlib import Path

import httpx
import pytest
from cryptography.fernet import Fernet
from fastapi import FastAPI
from fastapi.testclient import TestClient

from test_billing import load_main
from provider_admin import password_hash, active_provider, install_admin, ProviderConfigStore, ProviderSettings


@pytest.fixture
def owner(tmp_path, monkeypatch, request):
    config = getattr(request, "param", {})
    origin = config.get("origin", "https://testserver")
    monkeypatch.setenv("ADMIN_BASE_PATH", config.get("base_path", "/admin"))
    monkeypatch.setenv("ADMIN_SESSION_SECRET", "private-owner-test-secret-" * 3)
    monkeypatch.setenv("ADMIN_PASSWORD_HASH", password_hash("test-owner-password"))
    monkeypatch.setenv("ADMIN_ORIGIN", origin)
    monkeypatch.setenv("PROVIDER_CONFIG_PATH", str(tmp_path / "provider.enc"))
    monkeypatch.setenv("PROVIDER_CONFIG_ENCRYPTION_KEY", Fernet.generate_key().decode())
    monkeypatch.setenv("OPENAI_API_KEY", "original-api-secret")
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app, base_url=origin) as client:
        yield main, client


def login(client):
    r = client.post("/admin/api/login", headers={"Origin": "https://testserver"}, json={"password": "test-owner-password"})
    assert r.status_code == 200
    assert "HttpOnly" in r.headers["set-cookie"] and "Secure" in r.headers["set-cookie"]


def body(**changes):
    return dict(model="gpt-4o-transcribe", account_id="replacement-account", api_key="replacement-api-secret",
                expected_revision="environment", **changes)


def post(client, path, data):
    return client.post("/admin/api/" + path, headers={"Origin": "https://testserver"}, json=data)


def upstream(monkeypatch, status=200):
    import provider_admin
    calls = []
    class FakeClient:
        def __init__(self, **kwargs): assert kwargs["follow_redirects"] is False
        async def __aenter__(self): return self
        async def __aexit__(self, *args): pass
        async def post(self, url, **kwargs):
            calls.append((url, kwargs))
            return httpx.Response(status, json={"text": "Voice Type connection test."})
    monkeypatch.setattr(provider_admin.httpx, "AsyncClient", FakeClient)
    return calls


def test_console_is_disabled_without_credentials(tmp_path, monkeypatch):
    monkeypatch.delenv("ADMIN_SESSION_SECRET", raising=False)
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as c:
        assert c.get("/admin").status_code == 404
        assert c.get("/admin/api/state").status_code == 404


def test_auth_csrf_headers_and_logout_revoke_session(owner):
    _, c = owner
    assert c.get("/admin/api/state").status_code == 401
    assert c.post("/admin/api/login", json={"password": "test-owner-password"}).status_code == 403
    assert c.post("/admin/api/login", headers={"Origin": "https://attacker.example"}, json={"password": "test-owner-password"}).status_code == 403
    login(c)
    r = c.get("/admin/api/state")
    assert r.status_code == 200
    assert r.headers["cache-control"] == "no-store"
    assert "frame-ancestors 'none'" in r.headers["content-security-policy"]
    assert "original-api-secret" not in r.text
    stolen = c.cookies.get("__Secure-voicetype-admin")
    assert post(c, "logout", {}).status_code == 200
    c.cookies.set("__Secure-voicetype-admin", stolen)
    assert c.get("/admin/api/state").status_code == 401


def test_save_requires_exact_test_and_encrypts_history(owner, monkeypatch, tmp_path):
    main, c = owner; login(c); calls = upstream(monkeypatch)
    data = body()
    assert post(c, "config", data).status_code == 400
    test = post(c, "test", data)
    assert test.status_code == 200
    assert calls[0][0] == "https://api.openai.com/v1/audio/transcriptions"
    assert calls[0][1]["headers"]["Authorization"] == "Bearer replacement-api-secret"
    assert calls[0][1]["files"]["file"][1][:4] == b"RIFF"
    data["test_token"] = test.json()["test_token"]
    assert post(c, "config", {**data, "api_key": "changed-after-test"}).status_code == 400
    result = post(c, "config", data)
    assert result.status_code == 200
    assert main.provider_store.current().api_key == "replacement-api-secret"
    saved = (tmp_path / "provider.enc").read_bytes()
    assert b"replacement-api-secret" not in saved and b"original-api-secret" not in saved
    assert (tmp_path / "provider.enc").stat().st_mode & 0o777 == 0o600
    state = c.get("/admin/api/state")
    assert "replacement-api-secret" not in state.text and "original-api-secret" not in state.text
    assert len(state.json()["history"]) == 2
    assert post(c, "config", data).status_code == 409


def test_test_failure_and_unsupported_model_preserve_current(owner, monkeypatch):
    main, c = owner; login(c); upstream(monkeypatch, 429)
    assert post(c, "test", body()).status_code == 502
    assert main.provider_store.current().revision == "environment"
    assert post(c, "test", {**body(), "model": "arbitrary-unknown-model"}).status_code == 400


def test_restore_requires_fresh_test_and_keeps_account_ledger(owner, monkeypatch):
    main, c = owner; login(c); upstream(monkeypatch)
    data = body(); data["test_token"] = post(c, "test", data).json()["test_token"]
    revision = post(c, "config", data).json()["current"]["revision"]
    restore = {**body(), "expected_revision": revision, "restore_revision": "environment"}
    assert post(c, "config", restore).status_code == 400
    restore["test_token"] = post(c, "test", restore).json()["test_token"]
    assert post(c, "config", restore).status_code == 200
    assert main.provider_store.current().api_key == "original-api-secret"
    assert main.provider_store.current().revision != "environment"


def test_inflight_provider_snapshot_survives_configuration_change(owner):
    main, _ = owner
    original = main.provider_store.current()
    token = active_provider.set(original)
    try:
        main.provider_store.save(replace(original, api_key="new-secret", model="whisper-1"), "environment")
        assert main.resolve_model(None) == original.model
        assert main.request_provider().api_key == "original-api-secret"
    finally: active_provider.reset(token)
    assert main.resolve_model(None) == "whisper-1"
    assert main.request_provider().api_key == "new-secret"


def test_corrupt_configuration_fails_closed(owner, tmp_path):
    main, c = owner
    (tmp_path / "provider.enc").write_bytes(b"invalid encrypted data")
    with pytest.raises(RuntimeError): main.provider_store.current()
    assert c.get("/health/ready").status_code == 503


def test_proof_cannot_move_between_login_sessions(owner, monkeypatch):
    _, c = owner; login(c); upstream(monkeypatch)
    data = body(); data["test_token"] = post(c, "test", data).json()["test_token"]
    post(c, "logout", {}); login(c)
    assert post(c, "config", data).status_code == 400


def test_login_attempts_are_bounded(owner):
    _, c = owner
    for _ in range(12): assert post(c, "login", {"password": "wrong"}).status_code == 401
    assert post(c, "login", {"password": "wrong"}).status_code == 429


@pytest.mark.parametrize("owner", [{"base_path": "/voicetype/admin", "origin": "https://apeonwheels.com"}], indirect=True)
def test_company_prefix_routes_origin_cookie_scope_and_logout(owner, monkeypatch):
    _, c = owner
    prefix = "/voicetype/admin"
    origin = "https://apeonwheels.com"

    class PageLinks(HTMLParser):
        def __init__(self):
            super().__init__()
            self.base_path = None
            self.links = []
        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if tag == "html": self.base_path = attrs.get("data-admin-base-path")
            if tag in {"link", "script"}: self.links.append(attrs.get("href") or attrs.get("src"))

    page = c.get(prefix)
    assert page.status_code == 200 and "__ADMIN_BASE_PATH__" not in page.text
    parsed = PageLinks(); parsed.feed(page.text)
    assert parsed.base_path == prefix
    assert parsed.links == [prefix + "/assets/admin.css", prefix + "/assets/admin.js"]
    for url in parsed.links:
        response = c.get(url)
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store"
        assert response.headers["x-content-type-options"] == "nosniff"
    assert 'href="' + prefix + '"' in page.text
    assert c.get(prefix + "/").url.path == prefix
    assert c.get("/health").status_code == 200
    for path in ("/admin", "/admin/api/state", prefix + "-other", "/voicetype/administrator"):
        response = c.get(path)
        assert response.status_code == 404
        assert "x-frame-options" not in response.headers

    unauthenticated = c.get(prefix + "/api/state")
    assert unauthenticated.status_code == 401
    assert "frame-ancestors 'none'" in unauthenticated.headers["content-security-policy"]
    for path, data in [("logout", {}), ("test", body()), ("config", body())]:
        assert c.post(prefix + "/api/" + path, headers={"Origin": origin}, json=data).status_code == 401
    credentials = {"password": "test-owner-password"}
    for headers in ({}, {"Origin": "https://voicetype.y.dog"}, {"Origin": "https://attacker.example"},
                    {"Origin": origin, "Sec-Fetch-Site": "cross-site"}):
        assert c.post(prefix + "/api/login", headers=headers, json=credentials).status_code == 403

    response = c.post(prefix + "/api/login", headers={"Origin": origin}, json=credentials)
    assert response.status_code == 200
    cookie = response.headers["set-cookie"]
    assert "Path=" + prefix in cookie and "Domain=" not in cookie
    assert "Secure" in cookie and "HttpOnly" in cookie and "SameSite=strict" in cookie
    assert c.get(prefix + "/api/state").status_code == 200
    for path in ("/", "/voicetype/privacy/", "/admin", prefix + "-other"):
        assert "cookie" not in c.build_request("GET", path).headers

    upstream(monkeypatch)
    data = body()
    proof = c.post(prefix + "/api/test", headers={"Origin": origin}, json=data)
    assert proof.status_code == 200
    data["test_token"] = proof.json()["test_token"]
    assert c.post(prefix + "/api/config", headers={"Origin": origin}, json=data).status_code == 200
    stolen = c.cookies.get("__Secure-voicetype-admin")
    assert c.post(prefix + "/api/logout", headers={"Origin": "https://attacker.example"}, json={}).status_code == 403
    assert c.get(prefix + "/api/state").status_code == 200
    response = c.post(prefix + "/api/logout", headers={"Origin": origin}, json={})
    assert response.status_code == 200
    assert "Path=" + prefix in response.headers["set-cookie"] and "Max-Age=0" in response.headers["set-cookie"]
    assert not c.cookies.get("__Secure-voicetype-admin")
    c.cookies.set("__Secure-voicetype-admin", stolen, domain="apeonwheels.com", path=prefix)
    assert c.get(prefix + "/api/state").status_code == 401


@pytest.mark.parametrize("prefix", ["", "/", "admin", "//admin", "/admin/", "/a//admin", "/a/../admin",
                                    "/a/./admin", "/a%2Fadmin", "/admin?x=1", "/admin#x", "/a\\admin",
                                    "/admin\n", '/admin\"', "/" + "a" * 201,
                                    "/v1/admin", "/health", "/privacy", "/support/admin", "/docs/admin"])
def test_invalid_or_reserved_admin_prefix_fails_at_install(prefix, tmp_path, monkeypatch):
    monkeypatch.setenv("ADMIN_BASE_PATH", prefix)
    store = ProviderConfigStore("", "", lambda: ProviderSettings("whisper-1", "test", "test-key"))
    with pytest.raises(ValueError, match="ADMIN_BASE_PATH"):
        install_admin(FastAPI(), store, {}, logging.getLogger("test-owner-prefix"))


@pytest.mark.parametrize("prefix, existing", [("/private", "/private/status"), ("/private/admin", "/private/{page}"),
                                               ("/private/admin", "/private/{page}/api/{action}")])
def test_admin_prefix_cannot_overlap_existing_route(prefix, existing, monkeypatch):
    monkeypatch.setenv("ADMIN_BASE_PATH", prefix)
    app = FastAPI()
    app.add_api_route(existing, lambda: {"ok": True})
    store = ProviderConfigStore("", "", lambda: ProviderSettings("whisper-1", "test", "test-key"))
    with pytest.raises(ValueError, match="overlaps"):
        install_admin(app, store, {}, logging.getLogger("test-owner-prefix"))
