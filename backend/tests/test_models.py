from datetime import date

from fastapi.testclient import TestClient
from test_billing import auth, load_main
from test_reliability import fund


def test_catalog_lists_selectable_models_and_service_default(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        response = client.get("/v1/transcription/models")
    assert response.status_code == 200
    payload = response.json()
    assert payload["default_model"] == "gpt-transcribe"
    assert payload["default_model_name"] == "GPT Transcribe"
    models = {model["id"]: model for model in payload["models"]}
    assert list(models) == ["gpt-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"]
    recommended = models["gpt-transcribe"]
    assert recommended["recommended"] and recommended["streaming"] and recommended["retires_on"] is None
    # $0.0045 per minute with the default 71.43% markup, one credit per USD micro.
    assert recommended["credit_units_per_minute"] == 7_715
    assert recommended["formatted_per_minute"] == "7,715 credits/min"
    assert models["gpt-4o-mini-transcribe"]["credit_units_per_minute"] == 5_143
    assert models["whisper-1"]["retires_on"] == "2027-02-26" and not models["whisper-1"]["streaming"]
    assert not any(model["recommended"] for model in payload["models"][1:])


def test_catalog_hides_retired_models_and_reports_owner_default(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "OPENAI_TRANSCRIBE_MODEL", "gpt-4o-transcribe-diarize")
    monkeypatch.setitem(main.MODEL_RETIREMENTS, "whisper-1", date(2000, 1, 1))
    with TestClient(main.app) as client:
        payload = client.get("/v1/transcription/models").json()
    assert "whisper-1" not in [model["id"] for model in payload["models"]]
    assert payload["default_model"] == "gpt-4o-transcribe-diarize"
    assert payload["default_model_name"] == "GPT-4o Transcribe Diarize"


def test_explicit_model_choice_is_used_and_billed_by_duration(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append(args[3])
        return {"text": "hello", "usage": {"type": "duration", "seconds": 60}}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    monkeypatch.setattr(main, "OPENAI_TRANSCRIBE_MODEL", "gpt-4o-mini-transcribe")
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = client.post("/v1/transcriptions", headers=user["headers"],
            data={"audio_seconds": "60", "model": "gpt-transcribe"},
            files={"file": ("clip.m4a", b"audio", "audio/m4a")})
    assert response.status_code == 200, response.text
    assert calls == ["gpt-transcribe"]
    body = response.json()
    assert body["model"] == "gpt-transcribe"
    assert body["charge"]["cost_usd_micros"] == 7_715
    assert body["charge"]["pricing_basis"] == "duration"


def test_retired_model_choice_falls_back_to_service_default(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append(args[3])
        return {"text": "hello"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    monkeypatch.setitem(main.MODEL_RETIREMENTS, "gpt-4o-transcribe", date(2000, 1, 1))
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        def send(key):
            return client.post("/v1/transcriptions", headers={**user["headers"], "Idempotency-Key": key},
                data={"audio_seconds": "1", "model": "gpt-4o-transcribe"},
                files={"file": ("clip.m4a", b"audio", "audio/m4a")})
        first = send("retired-choice")
        assert first.status_code == 200, first.text
        assert first.json()["model"] == "gpt-transcribe"
        # The same request retried with the same choice replays the saved result.
        assert send("retired-choice").json() == first.json()
        unknown = client.post("/v1/transcriptions", headers=user["headers"],
            data={"audio_seconds": "1", "model": "gpt-unknown"},
            files={"file": ("clip.m4a", b"audio", "audio/m4a")})
    assert calls == ["gpt-transcribe"]
    assert unknown.status_code == 400


def test_model_retirement_starts_on_the_shutdown_date(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    assert not main.model_retired("gpt-4o-mini-transcribe", date(2027, 2, 25))
    assert main.model_retired("gpt-4o-mini-transcribe", date(2027, 2, 26))
    assert not main.model_retired("gpt-transcribe", date(2030, 1, 1))


def test_retired_service_default_uses_recommended_model(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append(args[3])
        return {"text": "hello"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    monkeypatch.setattr(main, "OPENAI_TRANSCRIBE_MODEL", "gpt-4o-mini-transcribe")
    monkeypatch.setitem(main.MODEL_RETIREMENTS, "gpt-4o-mini-transcribe", date(2000, 1, 1))
    with TestClient(main.app) as client:
        catalog = client.get("/v1/transcription/models").json()
        user = auth(client, "alice")
        fund(client, user)
        response = client.post("/v1/transcriptions", headers=user["headers"], data={"audio_seconds": "1"},
            files={"file": ("clip.m4a", b"audio", "audio/m4a")})
    assert catalog["default_model"] == "gpt-transcribe"
    assert response.status_code == 200, response.text
    assert calls == ["gpt-transcribe"]
