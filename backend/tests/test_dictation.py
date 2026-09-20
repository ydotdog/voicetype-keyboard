import asyncio
import json

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from test_billing import auth, load_main
from test_reliability import fund
from dictation import normalize_transcript, parse_context, provider_hints


@pytest.mark.parametrize("source,languages,expected", [
    ("你好, 今天怎么样? 我很好!", [], "你好，今天怎么样？ 我很好！"),
    ("我在臺灣, 軟體很好.", ["zh-Hans"], "我在台湾，软体很好。"),
    ("这是软件, 明天见.", ["zh-Hant"], "這是軟件，明天見。"),
    ("价格是3.14元, 明天10:30见.", [], "价格是3.14元，明天10:30见。"),
    ("请发到 a.b@example.com, 然后访问 https://example.com/a?q=1. 谢谢!", [], "请发到 a.b@example.com，然后访问 https://example.com/a?q=1。 谢谢！"),
    ("你好, OK. Hello, world!", [], "你好，OK。 Hello, world!"),
    ("Hello, world! Version 1.2.3.", ["zh-Hans"], "Hello, world! Version 1.2.3."),
    ("今日は良い天気です, ありがとう.", [], "今日は良い天気です, ありがとう."),
    ("今日, 東京.", ["ja"], "今日, 東京."),
    ('他说: "明天见", 好吗?', [], '他说：“明天见”，好吗？'),
    ("输入 `a.b(x)` 或 `繁體字`, 再试一次.", ["zh-Hans"], "输入 `a.b(x)` 或 `繁體字`，再试一次。"),
    ("请修改main.py文件, 然后访问example.xyz.", [], "请修改main.py文件，然后访问example.xyz。"),
    ('他说: "你好! 明天见。"', [], '他说：“你好！ 明天见。”'),
    ("今日は図書館です。明天見.", ["zh-Hans", "ja"], "今日は図書館です。明天见。"),
    ("让我想想...", [], "让我想想……"),
    ("金额1,234.56元, 网址example.com.", [], "金额1,234.56元，网址example.com。"),
])
def test_output_normalization(source, languages, expected):
    assert normalize_transcript(source, languages) == expected


def test_context_hints_and_limits():
    context = parse_context('["zh-Hans", "en"]', '["龚玥", "VoiceType", "voicetype"]')
    language, prompt = provider_hints(context)
    assert language is None
    assert "简体" in prompt and "龚玥" in prompt
    assert context["vocabulary"] == ["龚玥", "VoiceType"]
    assert provider_hints(parse_context('["zh-Hant"]'))[0] == "zh"
    for raw in ['"en"', '["xx"]', '["zh-Hans", "zh-Hant"]', '[1]', '["en","de","fr","es"]']:
        with pytest.raises(HTTPException): parse_context(raw)
    for raw in ['["a\\nb"]', '["<instructions>"]', '["x"]', '[123]']:
        with pytest.raises(HTTPException): parse_context(None, raw)


def test_context_is_forwarded_and_retries_do_not_rebill(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append((args, kwargs))
        return {"text": "龔玥, 明天見.", "usage": {"input_tokens": 20, "output_tokens": 10}}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        headers = {**user["headers"], "Idempotency-Key": "context-test"}
        data = {"audio_seconds": "1", "preferred_languages": '["zh-Hans"]', "vocabulary": '["龚玥"]'}
        def send(payload):
            return client.post("/v1/transcriptions", headers=headers, data=payload,
                               files={"file": ("clip.m4a", b"audio", "audio/m4a")})
        first = send(data)
        assert first.status_code == 200, first.text
        assert first.json()["transcript"] == "龚玥，明天见。"
        repeat = send(data)
        assert repeat.status_code == 200
        assert repeat.json()["id"] == first.json()["id"]
        assert len(calls) == 1
        assert calls[0][0][4] == "zh" and "龚玥" in calls[0][1]["prompt"]
        assert send({**data, "vocabulary": '["另一个名字"]'}).status_code == 409
        assert send({**data, "preferred_languages": '["en"]'}).status_code == 409
        assert send({**data, "preferred_languages": '["invalid"]'}).status_code == 422
    with main.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM transcriptions").fetchone()[0] == 1


def test_provider_receives_prompt_multipart(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    main.OPENAI_API_KEY = "test-key"
    captured = {}
    class Response:
        status_code = 200
        def json(self): return {"text": "你好"}
    class Client:
        def __init__(self, **kwargs): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *args): pass
        async def post(self, url, **kwargs):
            captured.update(kwargs)
            return Response()
    monkeypatch.setattr(main.httpx, "AsyncClient", Client)
    asyncio.run(main.transcribe_audio(b"audio", "clip.m4a", "audio/m4a", "gpt-4o-mini-transcribe", "zh", "龚玥"))
    assert captured["data"]["prompt"] == "龚玥"
    assert captured["data"]["language"] == "zh"
