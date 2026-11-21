"""Streamed transcription: server-sent events, billing, disconnects and replays."""

import asyncio
import json
from threading import BoundedSemaphore

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from provider_admin import transcription_form
from test_billing import auth, load_main
from test_reliability import fund

TOKEN_USAGE = {"type": "tokens", "input_tokens": 1_000, "output_tokens": 100, "total_tokens": 1_100}
NO_SPEECH = {"detail": "No speech was detected in this recording. Nothing was charged.", "code": "no_speech"}
UNAVAILABLE = "Transcription service is temporarily unavailable. Try again."
REQUEST_FAILED = "Transcription provider request failed."
INVALID_DATA = "Transcription provider returned invalid data."
NOTHING_SAVED = ([], {"transcriptions": 0, "credit_reservations": 0, "transcription_requests": 0})


def stream_request(client, user, *, key=None, model="gpt-4o-mini-transcribe", stream="true"):
    headers = {**user["headers"], **({"Idempotency-Key": key} if key else {})}
    data = {"audio_seconds": "1", "model": model, **({"stream": stream} if stream else {})}
    return client.post("/v1/transcriptions", headers=headers, data=data,
                       files={"file": ("clip.m4a", b"fake audio", "audio/m4a")})


def sse_events(body):
    """(event, data) pairs of a response body; keepalive comments are skipped."""
    events = []
    for block in body.split("\n\n"):
        fields = dict(line.split(": ", 1) for line in block.split("\n") if line and not line.startswith(":"))
        if fields:
            events.append((fields["event"], json.loads(fields["data"])))
    return events


def use_streaming_provider(monkeypatch, main, deltas, text, usage=TOKEN_USAGE, *, error=None):
    """Replaces the provider's streamed call. Returns the models it was asked for."""
    calls = []
    async def provider(*args, on_delta, **kwargs):
        calls.append(args[3])
        for delta in deltas:
            on_delta(delta)
            await asyncio.sleep(0)
        if error is not None:
            raise error
        return {"type": "transcript.text.done", "text": text, "usage": usage}
    async def unexpected(*args, **kwargs):
        raise AssertionError("a streamed request for a streaming model uses the streamed provider call")
    monkeypatch.setattr(main, "stream_transcribe_audio", provider)
    monkeypatch.setattr(main, "transcribe_audio", unexpected)
    return calls


def ledger(main):
    with main.db() as conn:
        debits = [tuple(row) for row in conn.execute(
            "SELECT amount_usd_micros, source_id FROM credit_ledger WHERE kind = 'transcription'")]
        counts = {table: conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                  for table in ("transcriptions", "credit_reservations", "transcription_requests")}
    return debits, counts


def assert_slot_free(main):
    assert main._transcription_slots.acquire(blocking=False)
    main._transcription_slots.release()


def asgi_request(user, key):
    """Scope and body of a streamed request, for driving the app as a server would."""
    request = httpx.Request(
        "POST", "http://testserver/v1/transcriptions",
        headers={**user["headers"], "Idempotency-Key": key},
        data={"audio_seconds": "1", "model": "gpt-4o-mini-transcribe", "stream": "true"},
        files={"file": ("clip.m4a", b"fake audio", "audio/m4a")},
    )
    scope = {
        # uvicorn's HTTP protocols report spec 2.3, so responses listen for disconnects.
        "type": "http", "asgi": {"version": "3.0", "spec_version": "2.3"}, "http_version": "1.1",
        "method": "POST", "scheme": "http", "path": "/v1/transcriptions", "raw_path": b"/v1/transcriptions",
        "root_path": "", "query_string": b"", "server": ("testserver", 80), "client": ("127.0.0.1", 50000),
        "headers": [(name.lower(), value) for name, value in request.headers.raw],
    }
    return scope, request.read()


async def leave_after_first_delta(main, scope, body):
    """Plays a client that disconnects once it has read the first delta. Returns what it read."""
    gone = asyncio.Event()
    pending = [{"type": "http.request", "body": body, "more_body": False}]
    sent = []
    async def receive():
        if pending:
            return pending.pop()
        await gone.wait()
        return {"type": "http.disconnect"}
    async def send(message):
        if gone.is_set():
            return  # uvicorn drops what an app sends to a closed connection.
        sent.append(message)
        if b"event: delta" in message.get("body", b""):
            gone.set()
    await main.app(scope, receive, send)
    return b"".join(message.get("body", b"") for message in sent if message["type"] == "http.response.body").decode()


@pytest.mark.parametrize("model, usage, seconds, input_tokens, output_tokens, basis", [
    ("gpt-4o-mini-transcribe", TOKEN_USAGE, 1.0, 1_000, 100, "reported_usage"),
    ("gpt-transcribe", {"type": "duration", "seconds": 3}, 3.0, None, None, "duration"),
])
def test_stream_sends_text_deltas_then_the_charged_result(tmp_path, monkeypatch, model, usage, seconds,
                                                          input_tokens, output_tokens, basis):
    main = load_main(tmp_path, monkeypatch)
    calls = use_streaming_provider(monkeypatch, main, ["你好, 今天", "怎么样?"], "你好, 今天怎么样?", usage)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = stream_request(client, user, key="streamed-clip", model=model)
    assert response.status_code == 200, response.text
    assert response.headers["content-type"].startswith("text/event-stream")
    assert response.headers["cache-control"] == "no-cache, no-transform"
    assert response.headers["x-accel-buffering"] == "no"
    *deltas, (kind, result) = sse_events(response.text)
    assert kind == "done"
    assert {name for name, _ in deltas} == {"delta"}
    # Deltas are the provider's raw text; only the final result is normalized.
    assert "".join(value["delta"] for _, value in deltas) == "你好, 今天怎么样?"
    assert result["transcript"] == "你好，今天怎么样？"
    # The final event is the body a request without stream=true receives.
    assert set(result) == set(main.TranscriptionResponse.model_fields)
    cost = main.calculate_cost(model=model, audio_seconds=seconds, transcript=result["transcript"],
                               input_tokens=input_tokens, output_tokens=output_tokens)[0]
    assert result["model"] == model
    assert result["charge"]["cost_usd_micros"] == cost
    assert result["charge"]["pricing_basis"] == basis
    assert result["balance"]["balance_usd_micros"] == 1_000_000 - cost
    assert calls == [model]
    assert ledger(main) == ([(-cost, f"transcription:{result['id']}")],
                            {"transcriptions": 1, "credit_reservations": 0, "transcription_requests": 1})


def test_client_that_leaves_mid_stream_is_charged_once_and_can_collect_the_result(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "_transcription_slots", BoundedSemaphore(1))
    gate, calls = {}, []
    async def provider(*args, on_delta, **kwargs):
        calls.append(args[3])
        on_delta("Finished")
        await gate["open"].wait()
        on_delta(" anyway.")
        return {"type": "transcript.text.done", "text": "Finished anyway.", "usage": TOKEN_USAGE}
    monkeypatch.setattr(main, "stream_transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        async def scenario():
            gate["open"] = asyncio.Event()
            received = await leave_after_first_delta(main, *asgi_request(user, "left-early"))
            # The response has ended; the transcription has not.
            [worker] = main._transcription_stream_tasks
            assert not worker.done()
            gate["open"].set()
            await worker
            assert not main._transcription_stream_tasks
            return received
        received = client.portal.call(scenario)
        retry = stream_request(client, user, key="left-early")
    assert sse_events(received) == [("delta", {"delta": "Finished"})]
    # The retry gets the saved result without another provider call.
    [(kind, result)] = sse_events(retry.text)
    assert (kind, result["transcript"]) == ("done", "Finished anyway.")
    assert calls == ["gpt-4o-mini-transcribe"]
    assert ledger(main) == ([(-result["charge"]["cost_usd_micros"], f"transcription:{result['id']}")],
                            {"transcriptions": 1, "credit_reservations": 0, "transcription_requests": 1})
    assert result["balance"]["balance_usd_micros"] == 1_000_000 - result["charge"]["cost_usd_micros"]
    assert_slot_free(main)


def test_retry_with_same_key_replays_the_saved_result_without_calling_the_provider(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = use_streaming_provider(monkeypatch, main, ["Saved", " words."], "Saved words.")
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        first = stream_request(client, user, key="stable-clip")
        replay = stream_request(client, user, key="stable-clip")
        plain = stream_request(client, user, key="stable-clip", stream=None)
    *_, (kind, result) = sse_events(first.text)
    assert kind == "done"
    assert sse_events(replay.text) == [("done", result)]
    # The key is shared with requests that do not stream.
    assert plain.headers["content-type"] == "application/json"
    assert plain.json() == result
    assert calls == ["gpt-4o-mini-transcribe"]
    assert ledger(main)[0] == [(-result["charge"]["cost_usd_micros"], f"transcription:{result['id']}")]


def test_model_that_cannot_stream_sends_only_the_final_event(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    calls = []
    async def provider(*args, **kwargs):
        calls.append(args[3])
        return {"text": "Whole clip.", "duration": 2.0}
    async def streaming_provider(*args, **kwargs):
        raise AssertionError("whisper-1 has no streamed output")
    monkeypatch.setattr(main, "transcribe_audio", provider)
    monkeypatch.setattr(main, "stream_transcribe_audio", streaming_provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = stream_request(client, user, model="whisper-1")
    assert response.status_code == 200, response.text
    [(kind, result)] = sse_events(response.text)
    assert kind == "done"
    assert (result["transcript"], result["model"]) == ("Whole clip.", "whisper-1")
    assert result["charge"]["pricing_basis"] == "duration"
    assert result["charge"]["cost_usd_micros"] == main.calculate_cost(
        model="whisper-1", audio_seconds=2.0, transcript="Whole clip.", input_tokens=None, output_tokens=None)[0]
    assert calls == ["whisper-1"]


@pytest.mark.parametrize("case, status", [("unfunded", 402), ("bad_key", 400), ("busy", 503), ("provider_down", 502)])
def test_failure_before_the_first_event_is_an_ordinary_http_error(tmp_path, monkeypatch, case, status):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "_transcription_slots", BoundedSemaphore(1))
    use_streaming_provider(monkeypatch, main, [], "", error=httpx.ConnectError("provider unreachable"))
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        if case != "unfunded":
            fund(client, user)
        if case == "busy":
            assert main._transcription_slots.acquire(blocking=False)
        try:
            response = stream_request(client, user, key="bad key!" if case == "bad_key" else "clip-1")
        finally:
            if case == "busy":
                main._transcription_slots.release()
    assert response.status_code == status, response.text
    assert response.headers["content-type"] == "application/json"
    if case == "busy":
        assert response.headers["retry-after"] == "3"
    if case == "provider_down":
        assert response.json() == {"detail": UNAVAILABLE}
    assert ledger(main) == NOTHING_SAVED
    assert_slot_free(main)


def test_silent_clip_without_text_is_an_ordinary_no_speech_error(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    use_streaming_provider(monkeypatch, main, [], " ")
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = stream_request(client, user, key="silent-clip")
        balance = client.get("/v1/me", headers=user["headers"])
    assert response.status_code == 422, response.text
    assert response.json() == NO_SPEECH
    assert balance.json()["balance"]["balance_usd_micros"] == 1_000_000
    assert ledger(main) == NOTHING_SAVED


def test_silence_after_blank_deltas_ends_the_stream_with_no_speech(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    use_streaming_provider(monkeypatch, main, [" "], "")
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = stream_request(client, user, key="silent-clip")
    assert response.status_code == 200, response.text
    assert sse_events(response.text) == [("delta", {"delta": " "}), ("error", {"status": 422, **NO_SPEECH})]
    assert ledger(main) == NOTHING_SAVED


@pytest.mark.parametrize("failure, status, detail", [
    (httpx.ReadError("connection reset"), 502, UNAVAILABLE),
    (HTTPException(status_code=502, detail=REQUEST_FAILED), 502, REQUEST_FAILED),
    (RuntimeError("unexpected"), 500, "Transcription failed. Try again."),
])
def test_failure_mid_stream_charges_nothing_and_frees_the_key_for_a_retry(tmp_path, monkeypatch, failure, status, detail):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "_transcription_slots", BoundedSemaphore(1))
    use_streaming_provider(monkeypatch, main, ["Half a"], "", error=failure)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        failed = stream_request(client, user, key="flaky-clip")
        after_failure = ledger(main)
        use_streaming_provider(monkeypatch, main, ["Whole"], "Whole sentence.")
        retry = stream_request(client, user, key="flaky-clip")
    assert failed.status_code == 200, failed.text
    assert sse_events(failed.text) == [("delta", {"delta": "Half a"}), ("error", {"status": status, "detail": detail})]
    assert after_failure == NOTHING_SAVED
    *_, (kind, result) = sse_events(retry.text)
    assert (kind, result["transcript"]) == ("done", "Whole sentence.")
    assert ledger(main)[0] == [(-result["charge"]["cost_usd_micros"], f"transcription:{result['id']}")]
    assert_slot_free(main)


def test_shutdown_lets_a_stream_whose_client_left_finish_and_charge(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "_transcription_slots", BoundedSemaphore(1))
    async def provider(*args, on_delta, **kwargs):
        on_delta("Almost")
        await asyncio.sleep(0.05)
        return {"type": "transcript.text.done", "text": "Almost done.", "usage": TOKEN_USAGE}
    monkeypatch.setattr(main, "stream_transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        async def scenario():
            await leave_after_first_delta(main, *asgi_request(user, "late-clip"))
            [worker] = main._transcription_stream_tasks
            return worker
        worker = client.portal.call(scenario)
        assert not worker.done()
    # Leaving the block shuts the application down, which waits for the worker.
    assert worker.done() and not worker.cancelled()
    [(amount, source)], counts = ledger(main)
    assert amount < 0 and source.startswith("transcription:")
    assert counts == {"transcriptions": 1, "credit_reservations": 0, "transcription_requests": 1}
    assert_slot_free(main)


def test_shutdown_cancels_a_stuck_stream_after_the_grace_period_without_charging(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "_transcription_slots", BoundedSemaphore(1))
    monkeypatch.setattr(main, "TRANSCRIPTION_STREAM_SHUTDOWN_GRACE_SECONDS", 0.01)
    async def provider(*args, on_delta, **kwargs):
        on_delta("Stuck")
        await asyncio.sleep(3600)
    monkeypatch.setattr(main, "stream_transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        async def scenario():
            await leave_after_first_delta(main, *asgi_request(user, "stuck-clip"))
            [worker] = main._transcription_stream_tasks
            await main.finish_transcription_streams()
            return worker
        worker = client.portal.call(scenario)
        assert worker.cancelled()
        assert not main._transcription_stream_tasks
    assert ledger(main) == NOTHING_SAVED
    assert_slot_free(main)


def test_slow_provider_keeps_the_connection_alive_with_comments(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    monkeypatch.setattr(main, "TRANSCRIPTION_STREAM_KEEPALIVE_SECONDS", 0.01)
    async def provider(*args, on_delta, **kwargs):
        on_delta("Slow")
        await asyncio.sleep(0.1)
        return {"type": "transcript.text.done", "text": "Slow speaker.", "usage": TOKEN_USAGE}
    monkeypatch.setattr(main, "stream_transcribe_audio", provider)
    with TestClient(main.app) as client:
        user = auth(client, "alice")
        fund(client, user)
        response = stream_request(client, user)
    assert ": keepalive\n\n" in response.text
    assert [name for name, _ in sse_events(response.text)] == ["delta", "done"]


def test_stream_field_is_sent_only_when_streaming():
    assert transcription_form("gpt-transcribe", stream=True)["stream"] == "true"
    assert "stream" not in transcription_form("gpt-transcribe")


def use_provider_response(monkeypatch, main, status, content_type, body):
    """Answers provider requests with `body`, one byte per chunk. Returns the requests."""
    requests = []
    async def byte_by_byte():
        for index in range(len(body)):
            yield body[index:index + 1]
    def respond(request):
        requests.append(request)
        return httpx.Response(status, headers={"content-type": content_type}, content=byte_by_byte())
    original = httpx.AsyncClient
    monkeypatch.setattr(main, "OPENAI_API_KEY", "fake-key")
    monkeypatch.setattr(main.httpx, "AsyncClient", lambda **kw: original(transport=httpx.MockTransport(respond), **kw))
    return requests


def stream_from_provider(main, model="gpt-4o-mini-transcribe"):
    deltas = []
    payload = asyncio.run(main.stream_transcribe_audio(b"audio", "clip.m4a", "audio/m4a", model, None,
                                                       on_delta=deltas.append))
    return deltas, payload


def test_provider_events_are_read_across_chunks_and_line_endings(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    body = (
        ": keep-alive\r\n\r\n"
        'data: {"type":"transcript.text.delta","delta":"你好"}\r\n\r\n'
        # JSON strings may hold U+2028 unescaped; it does not end a line.
        'event: transcript.text.delta\rdata: {"type":"transcript.text.delta","delta":" line break"}\r\r'
        'data: {"type":"transcript.text.delta",\r\ndata:"delta":"!"}\r\n\r\n'
        'data: {"type":"transcript.text.segment","text":"ignored"}\n\n'
        'data: {"type":"transcript.text.done","text":"你好 line break!",'
        '"usage":{"type":"tokens","input_tokens":3,"output_tokens":2,"total_tokens":5}}\n\n'
        "data: [DONE]\n\n"
    ).encode()
    requests = use_provider_response(monkeypatch, main, 200, "text/event-stream; charset=utf-8", body)
    deltas, payload = stream_from_provider(main)
    assert deltas == ["你好", " line break", "!"]
    assert payload["text"] == "你好 line break!"
    assert main.extract_usage(payload) == (3, 2)
    [request] = requests
    assert request.headers["accept"] == "text/event-stream"
    assert b'name="stream"\r\n\r\ntrue\r\n' in request.read()


DELTA = b'data: {"type":"transcript.text.delta","delta":"Hal"}\n\n'


@pytest.mark.parametrize("status, content_type, body, deltas, detail", [
    (200, "text/event-stream", DELTA + b'data: {"type":"error","error":{"code":"server_error","message":"account details"}}\n\n',
     ["Hal"], REQUEST_FAILED),
    (200, "text/event-stream", DELTA, ["Hal"], UNAVAILABLE),
    (200, "text/event-stream", DELTA + b"data: {not json}\n\n", ["Hal"], INVALID_DATA),
    (200, "text/event-stream", DELTA + b"data: [1, 2]\n\n", ["Hal"], INVALID_DATA),
    (200, "text/event-stream", DELTA + b'data: {"type":"transcript.text.delta","delta":"\xff"}\n\n', ["Hal"], INVALID_DATA),
    (500, "application/json", b'{"error":{"message":"account details"}}', [], REQUEST_FAILED),
    (200, "application/json", b"not json", [], INVALID_DATA),
])
def test_unusable_provider_streams_are_provider_errors(tmp_path, monkeypatch, status, content_type, body, deltas, detail):
    main = load_main(tmp_path, monkeypatch)
    use_provider_response(monkeypatch, main, status, content_type, body)
    received = []
    with pytest.raises(HTTPException) as failure:
        asyncio.run(main.stream_transcribe_audio(b"audio", "clip.m4a", "audio/m4a", "gpt-4o-mini-transcribe", None,
                                                 on_delta=received.append))
    assert (failure.value.status_code, failure.value.detail) == (502, detail)
    assert received == deltas


def test_provider_json_answer_to_a_stream_request_is_used_as_is(tmp_path, monkeypatch):
    main = load_main(tmp_path, monkeypatch)
    body = json.dumps({"text": "Whole clip.", "usage": {"type": "duration", "seconds": 2}}).encode()
    use_provider_response(monkeypatch, main, 200, "application/json", body)
    deltas, payload = stream_from_provider(main, "gpt-transcribe")
    assert deltas == []
    assert payload["text"] == "Whole clip."
