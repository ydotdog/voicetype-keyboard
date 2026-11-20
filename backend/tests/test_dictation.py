import asyncio
import json

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from test_billing import auth, load_main
from test_reliability import fund
from dictation import multilingual_hints, normalize_transcript, parse_context, provider_hints


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
    traditional_language, traditional_prompt = provider_hints(parse_context('["zh-Hant"]', '["龚玥"]'))
    assert traditional_language == "zh"
    assert "繁體中文" in traditional_prompt and "龔玥" in traditional_prompt
    assert "简体" not in traditional_prompt
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
        args, hints = calls[0]
        assert args[3] == "gpt-transcribe" and args[4] is None
        assert hints["languages"] == ["zh-cn"] and hints["keywords"] == ["龚玥"]
        assert "简体" in hints["prompt"] and "龚玥" not in hints["prompt"]
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


def test_multilingual_hints_map_languages_and_keywords():
    languages, keywords, prompt = multilingual_hints(parse_context('["zh-Hant", "en"]', '["龚玥", "VoiceType"]'))
    assert languages == ["zh-tw", "en"]
    assert keywords == ["龔玥", "VoiceType"]
    assert "繁體中文" in prompt and "龔玥" not in prompt
    assert multilingual_hints(parse_context('["ja"]'))[0] == ["ja"]
    assert multilingual_hints(parse_context(), "EN") == (["en"], [], None)
    # The provider rejects a whole request over one malformed code.
    assert multilingual_hints(parse_context(), "english")[0] == []
    assert multilingual_hints(parse_context(), "zh-HK")[0] == ["zh-hk"]


def test_legacy_model_choice_keeps_single_language_and_prompt_vocabulary(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append((args, kwargs))
        return {"text": "明天见"}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = client.post("/v1/transcriptions", headers=user["headers"],
            data={"audio_seconds": "1", "model": "gpt-4o-mini-transcribe",
                  "preferred_languages": '["zh-Hans"]', "vocabulary": '["龚玥"]'},
            files={"file": ("clip.m4a", b"audio", "audio/m4a")})
    assert response.status_code == 200, response.text
    assert response.json()["model"] == "gpt-4o-mini-transcribe"
    args, hints = calls[0]
    assert args[3] == "gpt-4o-mini-transcribe" and args[4] == "zh"
    assert "龚玥" in hints["prompt"] and "languages" not in hints and "keywords" not in hints


def test_gpt_transcribe_multipart_sends_language_list_and_keywords(tmp_path, monkeypatch):
    import httpx
    main = load_main(tmp_path, monkeypatch)
    main.OPENAI_API_KEY = "fake-key"
    bodies = []
    def respond(request):
        bodies.append(request.read())
        return httpx.Response(200, json={"text": "你好", "usage": {"type": "duration", "seconds": 1}})
    original = httpx.AsyncClient
    monkeypatch.setattr(main.httpx, "AsyncClient", lambda **kw: original(transport=httpx.MockTransport(respond), **kw))
    asyncio.run(main.transcribe_audio(b"audio", "clip.m4a", "audio/m4a", "gpt-transcribe", "zh",
                                      "风格提示", languages=["zh-cn", "en"], keywords=["龚玥", "VoiceType"]))
    body = bodies[0]
    for name, value in [("model", "gpt-transcribe"), ("response_format", "json"), ("languages[]", "zh-cn"),
                        ("languages[]", "en"), ("keywords[]", "龚玥"), ("keywords[]", "VoiceType"), ("prompt", "风格提示")]:
        assert f'name="{name}"\r\n\r\n{value}\r\n'.encode() in body
    assert b'name="language"' not in body
