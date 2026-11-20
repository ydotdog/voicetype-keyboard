"""Live transcription over a WebSocket, with a fake provider session (no OpenAI calls)."""

import asyncio
import base64
import json
import logging
import signal
import threading
import time
from array import array
from contextlib import asynccontextmanager

import anyio
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import realtime
from test_billing import auth, load_main
from test_reliability import fund, transcribe_key
from test_streaming import NOTHING_SAVED, ledger

LIVE = "gpt-live-transcribe"
ENDPOINT = "/v1/realtime/transcriptions"
FRAME = 4800  # 100 ms of 24 kHz 16-bit mono
LOUD = array("h", [8000, -8000] * (FRAME // 4)).tobytes()
SILENT = bytes(FRAME)
QUIET = array("h", [300, -300] * (FRAME // 4)).tobytes()
PREFS = '["zh-Hans","en"]'
VOCAB = '["VoiceType"]'
REALTIME_ENV = ("REALTIME_TRANSCRIPTION_ENABLED", "REALTIME_TRANSCRIPTION_MODEL", "MAX_CONCURRENT_REALTIME_SESSIONS",
                "REALTIME_ALLOWED_USER_IDS", "REALTIME_RATE_LIMIT_PER_WINDOW")
NO_ROWS = NOTHING_SAVED[1]
ONE_CLIP = {"transcriptions": 1, "credit_reservations": 0, "transcription_requests": 1}
FRAME_DETAIL = "Audio frames must be 16-bit PCM up to 32 KB."
SECONDS_DETAIL = "audio_seconds must be the recording length in seconds."
FIRST_MESSAGE = "The first message must start the recording."
UNAVAILABLE = {"type": "error", "status": 403, "code": "realtime_unavailable",
               "detail": "Live transcription is not available. Upload the recording instead."}
CANCELLED = {"type": "error", "status": 499, "code": "cancelled", "detail": "The recording was cancelled."}
DISCONNECTED = {"type": "error", "status": 499, "code": "disconnected",
                "detail": "The app disconnected before the recording ended."}
SUPERSEDED = {"type": "error", "status": 409, "code": "superseded", "detail": "A newer request is handling this recording."}
NO_SPEECH = {"type": "error", "status": 422, "code": "no_speech",
             "detail": "No speech was detected in this recording. Nothing was charged."}


def provider_failure(status):
    return {"type": "error", "status": status, "code": "provider_error", "detail": "Live transcription was interrupted."}


def protocol_failure(detail):
    return {"type": "error", "status": 400, "code": "protocol_error", "detail": detail}


def invalid_request(detail):
    return {"type": "error", "status": 400, "code": "invalid_request", "detail": detail}


def user_id(user):
    return user["payload"]["user"]["id"]


@pytest.fixture(autouse=True)
def no_provider_network(monkeypatch):
    @asynccontextmanager
    async def blocked(url, api_key):
        raise AssertionError("tests must not reach the provider")
        yield
    monkeypatch.setattr(realtime, "open_upstream", blocked)


def load_realtime_main(tmp_path, monkeypatch, **env):
    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.setenv("OPENAI_BASE_URL", "https://api.openai.com")
    monkeypatch.delenv("PROVIDER_CONFIG_PATH", raising=False)
    for name in REALTIME_ENV:
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    main = load_main(tmp_path, monkeypatch)
    async def no_upload(*args, **kwargs):
        raise AssertionError("unexpected upload transcription")
    monkeypatch.setattr(main, "transcribe_audio", no_upload)
    monkeypatch.setattr(main, "stream_transcribe_audio", no_upload)
    return main


def use_upload_provider(monkeypatch, main, text="uploaded words"):
    calls = []
    async def provider(*args, **kwargs):
        calls.append(args[3])
        return {"text": text}
    monkeypatch.setattr(main, "transcribe_audio", provider)
    return calls


class FakeProvider:
    """Stands in for OpenAI Realtime. Each connection gets its own FakeSession.

    turns are the texts of the committed turns, in order. gpt-live-transcribe
    sends one word per appended frame and the rest when the turn is committed;
    gpt-transcribe sends a turn's text only once it is committed. Clearing hold
    keeps committed turns from finishing.
    """

    def __init__(self, turns=("Hello world.",), *, ready=True, connect_error=None, close_after_ready=False,
                 commit_empty=False, error_on_append=None):
        self.turns = list(turns)
        self.connect_error = connect_error
        self.close_after_ready = close_after_ready
        self.commit_empty = commit_empty
        self.error_on_append = error_on_append
        self.ready_gate = threading.Event()
        self.hold = threading.Event()
        self.hold.set()
        self.commit_seen = threading.Event()
        if ready:
            self.ready_gate.set()
        self.sessions = []
        self.connections = []

    @property
    def session(self):
        return self.sessions[-1]

    @asynccontextmanager
    async def connect(self, url, api_key):
        self.connections.append((url, api_key))
        if self.connect_error is not None:
            raise self.connect_error
        session = FakeSession(self)
        self.sessions.append(session)
        try:
            yield session
        finally:
            session.closed = True
            for task in session.tasks:
                task.cancel()


class FakeSession:
    def __init__(self, provider):
        self.provider = provider
        self.events = asyncio.Queue()
        self.config = None
        self.model = None
        self.sent = []
        self.audio_bytes = 0
        self.turn_bytes = 0
        self.items = 0
        self.spoken = 0
        self.closed = False
        self.tasks = []
        self.emit({"type": "session.created"})

    def emit(self, event):
        # None ends the provider connection.
        self.events.put_nowait(None if event is None else json.dumps(event))

    def __aiter__(self):
        return self

    async def __anext__(self):
        raw = await self.events.get()
        if raw is None:
            raise StopAsyncIteration
        return raw

    def open_words(self):
        turns = self.provider.turns
        return turns[self.items].split() if self.items < len(turns) else []

    def delta(self, item, words, index):
        return {"type": "conversation.item.input_audio_transcription.delta", "item_id": item,
                "delta": words[index] if index == 0 else " " + words[index]}

    async def send(self, raw):
        event = json.loads(raw)
        kind = event["type"]
        self.sent.append(kind)
        if kind == "session.update":
            self.config = event
            self.model = event["session"]["audio"]["input"]["transcription"]["model"]
            self.tasks.append(asyncio.ensure_future(self.announce_ready()))
        elif kind == "input_audio_buffer.append":
            size = len(base64.b64decode(event["audio"]))
            self.audio_bytes += size
            self.turn_bytes += size
            if self.provider.error_on_append:
                self.emit({"type": "error", "error": self.provider.error_on_append})
                return
            words = self.open_words()
            if self.model == LIVE and self.spoken < len(words):
                self.emit(self.delta(f"item_{self.items + 1}", words, self.spoken))
                self.spoken += 1
        elif kind == "input_audio_buffer.commit":
            self.provider.commit_seen.set()
            if self.provider.commit_empty:
                self.emit({"type": "error", "error": {"type": "invalid_request_error",
                                                      "code": "input_audio_buffer_commit_empty"}})
                return
            words, spoken = self.open_words(), self.spoken
            self.items += 1
            item = f"item_{self.items}"
            seconds = round(self.turn_bytes / 48_000, 2)
            self.turn_bytes = 0
            self.spoken = 0
            self.emit({"type": "input_audio_buffer.committed", "item_id": item})
            self.tasks.append(asyncio.ensure_future(self.finish_turn(item, words, spoken, seconds)))
        elif kind == "input_audio_buffer.clear":
            self.turn_bytes = 0
            self.emit({"type": "input_audio_buffer.cleared"})

    async def announce_ready(self):
        while not self.provider.ready_gate.is_set():
            await asyncio.sleep(0.01)
        self.emit({"type": "session.updated"})
        if self.provider.close_after_ready:
            self.emit(None)

    async def finish_turn(self, item, words, spoken, seconds):
        while not self.provider.hold.is_set():
            await asyncio.sleep(0.01)
        if self.model == LIVE:
            for index in range(spoken, len(words)):
                self.emit(self.delta(item, words, index))
        self.emit({"type": "conversation.item.input_audio_transcription.completed", "item_id": item,
                   "transcript": " ".join(words), "usage": {"type": "duration", "seconds": seconds}})


def use_provider(monkeypatch, provider):
    monkeypatch.setattr(realtime, "open_upstream", provider.connect)
    return provider


def receive(ws, timeout=5):
    """The next message from the server. TestClient's own receive() has no timeout."""
    async def within():
        with anyio.fail_after(timeout):
            return await ws._send_rx.receive()
    return ws.portal.call(within)


def receive_json(ws, timeout=5):
    message = receive(ws, timeout)
    assert message["type"] == "websocket.send", message
    return json.loads(message["text"])


def read_until_close(ws, timeout=5):
    """The server's messages and close code. Reading to the close lets the server finish its work."""
    messages = []
    while True:
        message = receive(ws, timeout)
        if message["type"] == "websocket.close":
            return messages, message.get("code", 1000)
        messages.append(json.loads(message["text"]))


def connect(client, user, key="clip-1", protocols=(realtime.PROTOCOL,)):
    headers = dict(user["headers"])
    if key is not None:
        headers["Idempotency-Key"] = key
    kwargs = {} if protocols is None else {"subprotocols": list(protocols)}
    return client.websocket_connect(ENDPOINT, headers=headers, **kwargs)


def start(ws, **fields):
    ws.send_text(json.dumps({"type": "start", "format": realtime.AUDIO_FORMAT, **fields}))


def begin(ws, **fields):
    start(ws, **fields)
    ready = receive_json(ws)
    assert ready["type"] == "ready", ready
    return ready


def send_frames(ws, frames):
    for frame in frames:
        ws.send_bytes(frame)


def commit(ws, seconds):
    ws.send_text(json.dumps({"type": "commit", "audio_seconds": seconds}))


def cancel(ws):
    ws.send_text(json.dumps({"type": "cancel"}))


def record_clip(ws, frames=(LOUD,) * 10, seconds=1.0):
    send_frames(ws, frames)
    commit(ws, seconds)
    return read_until_close(ws)


def wait_until(condition, timeout=5.0):
    deadline = time.monotonic() + timeout
    while not condition():
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.01)


def claim(main, key="clip-1"):
    with main.db() as conn:
        row = conn.execute("SELECT * FROM transcription_requests WHERE request_key = ?", (key,)).fetchone()
    return main.row_to_dict(row) or None


def upload(client, user, key="clip-1", **fields):
    return client.post(
        "/v1/transcriptions", headers={**user["headers"], "Idempotency-Key": key},
        data={"audio_seconds": "1", **fields}, files={"file": ("clip.m4a", b"fake audio", "audio/m4a")},
    )


def done_body(done):
    return {key: value for key, value in done.items() if key != "type"}


class Records(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records = []

    def emit(self, record):
        self.records.append(record)

    def named(self, message):
        return [record for record in self.records if record.getMessage() == message]


@pytest.fixture
def api_logs():
    handler = Records()
    target = logging.getLogger("voicetype.api")
    target.addHandler(handler)
    yield handler
    target.removeHandler(handler)


def test_live_clip_shows_text_while_speaking_and_charges_once(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            assert ws.accepted_subprotocol == realtime.PROTOCOL
            ready = begin(ws)
            messages, code = record_clip(ws)
        # An upload of the same recording replays the live result.
        replay = transcribe_key(client, alice, "clip-1")
        wait_until(lambda: main._realtime_sessions == {})
    assert ready == {"type": "ready", "session_id": ready["session_id"], "model": LIVE,
                     "text_timing": "while_speaking", "credit_units_per_minute": 29_144}
    *partials, done = messages
    assert partials[0] == {"type": "partial", "text": "Hello", "truncated": False}
    assert all(p["type"] == "partial" and "Hello world.".startswith(p["text"]) for p in partials)
    assert done == {
        "type": "done", "id": done["id"], "transcript": "Hello world.", "model": LIVE,
        "charge": {"cost_usd_micros": 487, "cost_credit_units": 487, "formatted": "487 credits",
                   "pricing_basis": "duration"},
        "balance": {"balance_usd_micros": 999_513, "balance_credit_units": 999_513, "formatted": "999,513 credits"},
    }
    assert code == 1000
    assert replay.status_code == 200, replay.text
    assert replay.json() == done_body(done)
    assert ledger(main) == ([(-487, f"transcription:{done['id']}")], ONE_CLIP)
    saved = claim(main)
    assert (saved["fingerprint_version"], saved["transcription_id"], saved["selected_model"]) == (3, done["id"], LIVE)
    assert saved["realtime_committed_at"]
    assert provider.connections == [("wss://api.openai.com/v1/realtime?intent=transcription", "test-openai-key")]
    assert len(provider.sessions) == 1
    session = provider.session
    # Turns are committed by the server, so the provider drops no audio as silence.
    assert session.config["session"]["audio"]["input"]["turn_detection"] is None
    assert session.audio_bytes == 48_000
    assert session.sent.count("input_audio_buffer.commit") == 1
    assert session.closed


def test_gpt_transcribe_commits_at_pauses_and_shows_each_finished_turn(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider(("First part.", "Second part.")))
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws, model="gpt-transcribe")
            messages, code = record_clip(ws, (LOUD,) * 10 + (SILENT,) * 10 + (LOUD,) * 10, 3.0)
    assert (ready["model"], ready["text_timing"], ready["credit_units_per_minute"]) == (
        "gpt-transcribe", "after_pauses", 7_715)
    *partials, done = messages
    assert partials[0] == {"type": "partial", "text": "First part.", "truncated": False}
    assert (done["transcript"], done["model"], done["charge"]["cost_usd_micros"], code) == (
        "First part. Second part.", "gpt-transcribe", 386, 1000)
    assert provider.session.sent.count("input_audio_buffer.commit") == 2
    assert ledger(main) == ([(-386, f"transcription:{done['id']}")], ONE_CLIP)


def test_trailing_silence_is_cleared_but_still_charged(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider(("First part.",)))
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            begin(ws, model="gpt-transcribe")
            messages, code = record_clip(ws, (LOUD,) * 10 + (SILENT,) * 10, 2.0)
    done = messages[-1]
    assert (done["transcript"], done["charge"]["cost_usd_micros"], code) == ("First part.", 258, 1000)
    assert provider.session.sent.count("input_audio_buffer.commit") == 1
    assert "input_audio_buffer.clear" in provider.session.sent


def test_audio_sent_before_the_provider_is_ready_is_forwarded_once_it_is(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider(ready=False))
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            start(ws)
            send_frames(ws, (LOUD,) * 10)
            commit(ws, 1.0)
            wait_until(lambda: (claim(main) or {}).get("realtime_committed_at"))
            assert provider.session.audio_bytes == 0
            provider.ready_gate.set()
            messages, code = read_until_close(ws)
    assert messages[0]["type"] == "ready"
    assert (messages[-1]["type"], messages[-1]["transcript"], code) == ("done", "Hello world.", 1000)
    assert provider.session.audio_bytes == 48_000


def test_dictation_preferences_reach_the_provider_and_the_replay_check(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    languages, keywords, prompt = main.multilingual_hints(main.parse_context(PREFS, VOCAB), None)
    assert (languages, keywords) == (["zh-cn", "en"], ["VoiceType"]) and prompt
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            begin(ws, preferred_languages=PREFS, vocabulary=VOCAB)
            messages, _ = record_clip(ws)
        same = upload(client, alice, preferred_languages=PREFS, vocabulary=VOCAB)
        different = transcribe_key(client, alice, "clip-1")
    assert provider.session.config == realtime.session_update(LIVE, languages=languages, keywords=keywords,
                                                              prompt=prompt)
    assert same.status_code == 200, same.text
    assert same.json()["id"] == messages[-1]["id"]
    assert different.status_code == 409
    assert different.json()["detail"] == "This request key was already used for a different recording."


@pytest.mark.parametrize("protocols, token", [
    (None, None),
    (("voicetype.realtime.v0",), None),
    ((realtime.PROTOCOL,), "not-a-token"),
])
def test_refused_before_the_handshake(tmp_path, monkeypatch, protocols, token):
    # The app sees an HTTP 403, as from a server without live transcription, and uploads instead.
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        user = {"headers": {"Authorization": f"Bearer {token}"}} if token else alice
        with pytest.raises(WebSocketDisconnect) as refused:
            with connect(client, user, protocols=protocols):
                pass
    assert refused.value.code == 1008
    assert provider.connections == []
    assert ledger(main) == NOTHING_SAVED


@pytest.mark.parametrize("key", [None, "bad key!", "x" * 129])
def test_request_key_is_required(tmp_path, monkeypatch, key):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        with connect(client, alice, key=key) as ws:
            assert read_until_close(ws) == ([invalid_request("Invalid transcription request key.")], 1008)


@pytest.mark.parametrize("env", [{"REALTIME_TRANSCRIPTION_ENABLED": "false"}, {"OPENAI_API_KEY": ""}])
def test_unavailable_when_turned_off_or_without_a_provider_key(tmp_path, monkeypatch, env):
    main = load_realtime_main(tmp_path, monkeypatch, **env)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        catalog = client.get("/v1/transcription/models").json()
        with connect(client, alice) as ws:
            start(ws)
            assert read_until_close(ws) == ([UNAVAILABLE], 1008)
    assert catalog["realtime"]["available"] is False
    assert provider.connections == []


def test_user_list_limits_who_can_start_a_live_session(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        bob = auth(client, "bob")
        fund(client, alice)
        fund(client, bob)
        monkeypatch.setattr(main, "REALTIME_ALLOWED_USER_IDS", frozenset({user_id(alice)}))
        # The catalog has no account, so the list is checked when a session starts.
        assert client.get("/v1/transcription/models").json()["realtime"]["available"] is True
        with connect(client, bob) as ws:
            start(ws)
            assert read_until_close(ws) == ([UNAVAILABLE], 1008)
        with connect(client, alice) as ws:
            begin(ws)
            cancel(ws)
            assert read_until_close(ws) == ([CANCELLED], 1000)


def test_sessions_are_rate_limited_per_account(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    monkeypatch.setattr(main, "RATE_LIMIT_ENABLED", True)
    monkeypatch.setattr(main, "REALTIME_RATE_LIMIT_PER_WINDOW", 1)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice, key="clip-1") as ws:
            begin(ws)
            cancel(ws)
            assert read_until_close(ws) == ([CANCELLED], 1000)
        with connect(client, alice, key="clip-2") as ws:
            start(ws)
            messages, code = read_until_close(ws)
    assert messages[0].pop("retry_after") >= 1
    assert (messages, code) == ([{"type": "error", "status": 429, "code": "rate_limited",
                                  "detail": "Too many requests. Please retry shortly."}], 1008)
    assert ledger(main) == NOTHING_SAVED


def test_first_minute_must_be_affordable(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        with connect(client, alice) as ws:
            start(ws)
            assert read_until_close(ws) == ([{"type": "error", "status": 402, "code": "insufficient_credit",
                                              "detail": "Insufficient credit. Need at least 29,144 credits."}], 1008)
    assert ledger(main) == NOTHING_SAVED
    assert provider.connections == []


def test_session_ends_when_credit_runs_out_and_pays_for_the_audio_sent(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    # The first minute's hold covers one second; the next second needs more than is left.
    monkeypatch.setattr(main, "REALTIME_HOLD_AHEAD_SECONDS", 59)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice, 40_000)
        with connect(client, alice) as ws:
            ready = begin(ws)
            send_frames(ws, (LOUD,) * 15)
            messages, code = read_until_close(ws)
    assert (messages[-1], code) == ({"type": "error", "status": 402, "code": "credit_exhausted",
                                     "detail": "Your credit ran out during this recording."}, 1008)
    assert provider.session.audio_bytes == 48_000
    assert ledger(main) == ([(-487, f"realtime:{ready['session_id']}")], NO_ROWS)


def test_busy_server_sends_the_app_to_upload(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch, MAX_CONCURRENT_REALTIME_SESSIONS="1")
    use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        bob = auth(client, "bob")
        fund(client, alice)
        fund(client, bob)
        with connect(client, alice) as first:
            begin(first)
            with connect(client, bob, key="clip-2") as second:
                start(second)
                assert read_until_close(second) == ([{
                    "type": "error", "status": 503, "code": "busy",
                    "detail": "Live transcription is busy. Upload the recording instead.", "retry_after": 3,
                }], 1011)
            messages, code = record_clip(first)
    assert (messages[-1]["type"], code) == ("done", 1000)


def test_request_key_used_before_cannot_start_a_live_session(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice, key="clip-1") as ws:
            begin(ws)
            record_clip(ws)
        use_upload_provider(monkeypatch, main)
        assert transcribe_key(client, alice, "clip-2").status_code == 200
        for key in ("clip-1", "clip-2"):
            with connect(client, alice, key=key) as ws:
                start(ws)
                assert read_until_close(ws) == ([{
                    "type": "error", "status": 409, "code": "key_used",
                    "detail": "This request key was already used. Upload the recording instead.",
                }], 1008)
    assert len(provider.sessions) == 1


@pytest.mark.parametrize("end, stopping, error, close_code, charged", [
    (cancel, False, CANCELLED, 1000, True),
    (lambda ws: ws.close(1001), False, DISCONNECTED, 1008, True),
    # Uvicorn closes each WebSocket with 1012 as it stops: the app uploads, and the audio is not charged.
    (lambda ws: ws.close(1012), True, {"type": "error", "status": 503, "code": "server_restarting",
                                       "detail": "The server is restarting."}, 1011, False),
    # The same code from the app while the server keeps running is an ordinary disconnect.
    (lambda ws: ws.close(1012), False, DISCONNECTED, 1008, True),
], ids=["cancel", "app-left", "server-restart", "app-sends-1012"])
def test_unfinished_clip_pays_for_the_audio_sent(tmp_path, monkeypatch, end, stopping, error, close_code, charged):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            send_frames(ws, (LOUD,) * 10)
            wait_until(lambda: provider.session.audio_bytes == 48_000)
            monkeypatch.setattr(main, "_server_stopping", stopping)
            end(ws)
            messages, code = read_until_close(ws)
        wait_until(lambda: main._realtime_sessions == {})
    assert (messages[-1], code) == (error, close_code)
    assert ledger(main) == ([(-487, f"realtime:{ready['session_id']}")] if charged else [], NO_ROWS)


def test_stop_signal_is_noted_before_uvicorn_handles_it(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    handled = []
    # Uvicorn's handler for SIGTERM, and no handler for SIGINT.
    handlers = {signal.SIGTERM: lambda signum, frame: handled.append(signum), signal.SIGINT: signal.SIG_DFL}
    monkeypatch.setattr(signal, "getsignal", handlers.get)
    monkeypatch.setattr(signal, "signal", handlers.__setitem__)
    monkeypatch.setattr(main, "_server_stopping", False)
    main.watch_for_server_stop()
    assert handlers[signal.SIGINT] is signal.SIG_DFL
    handlers[signal.SIGTERM](signal.SIGTERM, None)
    assert main._server_stopping
    assert handled == [signal.SIGTERM]


def test_committed_clip_finishes_after_the_app_leaves_and_its_upload_waits(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    provider.hold.clear()
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            begin(ws)
            send_frames(ws, (LOUD,) * 10)
            commit(ws, 1.0)
            assert provider.commit_seen.wait(5)
            send_frames(ws, (LOUD,) * 2)  # After the commit: not part of the clip.
            ws.close(1001)
            waiting = transcribe_key(client, alice, "clip-1")
            provider.hold.set()
            messages, code = read_until_close(ws)
        wait_until(lambda: main._realtime_sessions == {})
        replay = transcribe_key(client, alice, "clip-1")
    assert waiting.status_code == 409
    assert waiting.json()["detail"].startswith("This recording is still being transcribed.")
    assert 1 <= int(waiting.headers["retry-after"]) <= 35
    done = messages[-1]
    assert (done["type"], done["transcript"], code) == ("done", "Hello world.", 1000)
    assert replay.status_code == 200, replay.text
    assert replay.json()["id"] == done["id"]
    assert provider.session.audio_bytes == 48_000
    assert ledger(main) == ([(-487, f"transcription:{done['id']}")], ONE_CLIP)


def test_upload_takes_over_a_clip_still_recording(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            send_frames(ws, (LOUD,) * 10)
            wait_until(lambda: provider.session.audio_bytes == 48_000)
            calls = use_upload_provider(monkeypatch, main)
            taken_over = transcribe_key(client, alice, "clip-1")
            messages, code = read_until_close(ws)
        wait_until(lambda: main._realtime_sessions == {})
    assert taken_over.status_code == 200, taken_over.text
    body = taken_over.json()
    assert body["transcript"] == "uploaded words"
    # The live model is not offered for uploads, so the upload uses the server default.
    assert calls == [main.resolve_model(None)]
    assert (messages[-1], code) == (SUPERSEDED, 1008)
    debits, counts = ledger(main)
    assert sorted(debits) == sorted([(-487, f"realtime:{ready['session_id']}"),
                                     (-body["charge"]["cost_usd_micros"], f"transcription:{body['id']}")])
    assert counts == ONE_CLIP


def test_provider_error_ends_the_session_and_logs_codes_only(tmp_path, monkeypatch, api_logs):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider(error_on_append={
        "type": "invalid_request_error", "code": "bad_audio", "message": "quoted secret words"}))
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            send_frames(ws, (LOUD,))
            messages, code = read_until_close(ws)
    assert (messages[-1], code) == (provider_failure(502), 1011)
    assert ledger(main) == ([(-50, f"realtime:{ready['session_id']}")], NO_ROWS)
    [record] = api_logs.named("realtime_provider_error")
    assert (record.event_type, record.error_type, record.error_code) == ("error", "invalid_request_error", "bad_audio")
    formatter = main.JsonExtraFormatter()
    assert not any("quoted secret words" in formatter.format(r) for r in api_logs.records)


def test_provider_connection_failure_is_free(tmp_path, monkeypatch, api_logs):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider(connect_error=OSError("no route")))
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            start(ws)
            assert read_until_close(ws) == ([provider_failure(502)], 1011)
    assert ledger(main) == NOTHING_SAVED
    assert [record.error for record in api_logs.named("realtime_upstream_closed")] == ["OSError"]


def test_provider_closing_the_session_ends_it(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider(close_after_ready=True))
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            start(ws)
            messages, code = read_until_close(ws)
    assert [message["type"] for message in messages] == ["ready", "error"]
    assert (messages[-1], code) == (provider_failure(502), 1011)
    assert ledger(main) == NOTHING_SAVED


def test_provider_that_never_gets_ready_times_out(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider(ready=False))
    monkeypatch.setattr(realtime, "UPSTREAM_READY_TIMEOUT_SECONDS", 0.2)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            start(ws)
            assert read_until_close(ws) == ([provider_failure(503)], 1011)
    assert ledger(main) == NOTHING_SAVED


def test_audio_held_for_a_slow_provider_is_limited(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider(ready=False))
    monkeypatch.setattr(realtime, "MAX_PENDING_SECONDS", 0.5)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            start(ws)
            send_frames(ws, (LOUD,) * 6)
            assert read_until_close(ws) == ([provider_failure(503)], 1011)
    assert ledger(main) == NOTHING_SAVED


@pytest.mark.parametrize("send_first, error", [
    (lambda ws: commit(ws, 1.0), protocol_failure(FIRST_MESSAGE)),
    (lambda ws: ws.send_text("not json"), protocol_failure(FIRST_MESSAGE)),
    (lambda ws: ws.send_text("[" * 16_000 + "]" * 16_000), protocol_failure(FIRST_MESSAGE)),
    (lambda ws: ws.send_bytes(LOUD), protocol_failure(FIRST_MESSAGE)),
    (lambda ws: start(ws, format="opus"), protocol_failure("Audio must be pcm_s16le_24000_mono.")),
    (lambda ws: start(ws, model="whisper-1"), {"type": "error", "status": 400, "code": "unsupported_model",
                                               "detail": "This model does not support live transcription."}),
    (lambda ws: start(ws, model="m" * 129), invalid_request("model must be text of at most 128 characters.")),
    (lambda ws: start(ws, language=5), invalid_request("language must be text of at most 32 characters.")),
    (lambda ws: start(ws, preferred_languages='["xx"]'),
     invalid_request("Choose supported languages and one Chinese writing style.")),
], ids=["commit", "not-json", "nested-json", "audio", "format", "upload-only-model", "long-model", "language-number",
        "languages"])
def test_bad_start_message_ends_the_session_before_anything_is_held(tmp_path, monkeypatch, send_first, error):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            send_first(ws)
            assert read_until_close(ws) == ([error], 1008)
    assert ledger(main) == NOTHING_SAVED
    assert provider.connections == []


@pytest.mark.parametrize("send, detail", [
    (lambda ws: ws.send_bytes(b"\x00" * 3), FRAME_DETAIL),
    (lambda ws: ws.send_bytes(b""), FRAME_DETAIL),
    (lambda ws: ws.send_bytes(bytes(32_770)), FRAME_DETAIL),
    (lambda ws: ws.send_text('{"type":"pause"}'), "Unexpected message."),
    (lambda ws: ws.send_text("{"), "Unexpected message."),
    # Too deep for the JSON decoder: still the app's mistake, not a server fault.
    (lambda ws: ws.send_text("[" * 16_000 + "]" * 16_000), "Unexpected message."),
    (lambda ws: commit(ws, "1"), SECONDS_DETAIL),
    (lambda ws: commit(ws, -1), SECONDS_DETAIL),
    (lambda ws: commit(ws, True), SECONDS_DETAIL),
    (lambda ws: ws.send_text('{"type":"commit","audio_seconds":NaN}'), SECONDS_DETAIL),
    (lambda ws: ws.send_text('{"type":"commit","audio_seconds":1' + "0" * 400 + "}"), SECONDS_DETAIL),
    (lambda ws: commit(ws, 602), SECONDS_DETAIL),
], ids=["odd-frame", "empty-frame", "large-frame", "unknown-type", "not-json", "nested-json", "seconds-text",
        "seconds-negative", "seconds-bool", "seconds-nan", "seconds-huge", "seconds-too-long"])
def test_bad_message_during_a_session_ends_it(tmp_path, monkeypatch, send, detail):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            begin(ws)
            send(ws)
            messages, code = read_until_close(ws)
    assert (messages[-1], code) == (protocol_failure(detail), 1008)
    assert ledger(main) == NOTHING_SAVED


def test_second_commit_is_refused(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    provider.hold.clear()
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            send_frames(ws, (LOUD,) * 10)
            commit(ws, 1.0)
            commit(ws, 1.0)
            messages, code = read_until_close(ws)
    assert (messages[-1], code) == (protocol_failure("The recording was already committed."), 1008)
    assert ledger(main) == ([(-487, f"realtime:{ready['session_id']}")], NO_ROWS)


def test_audio_faster_than_recording_is_refused(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    monkeypatch.setattr(realtime, "INGEST_BURST_SECONDS", 0.5)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            send_frames(ws, (LOUD,) * 50)
            messages, code = read_until_close(ws)
    assert (messages[-1], code) == (protocol_failure("Audio is arriving faster than it can be recorded."), 1008)
    cost = main.realtime_cost(LIVE, provider.session.audio_bytes / 48_000, minimum=False)
    assert ledger(main) == ([(-cost, f"realtime:{ready['session_id']}")] if cost else [], NO_ROWS)


def test_clip_missing_live_audio_falls_back_to_upload(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            # One second arrived for a five-second recording.
            messages, code = record_clip(ws, seconds=5.0)
        wait_until(lambda: main._realtime_sessions == {})
        live_ledger = ledger(main)
        use_upload_provider(monkeypatch, main)
        fallback = transcribe_key(client, alice, "clip-1")
    assert (messages[-1], code) == ({"type": "error", "status": 409, "code": "fallback_required",
                                     "detail": "Live audio is incomplete. Upload the recording instead."}, 1008)
    assert live_ledger == ([(-487, f"realtime:{ready['session_id']}")], NO_ROWS)
    assert fallback.status_code == 200, fallback.text


def test_recording_length_is_limited(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    monkeypatch.setattr(realtime, "MAX_AUDIO_SECONDS", 1)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            send_frames(ws, (LOUD,) * 11)
            messages, code = read_until_close(ws)
    assert (messages[-1]["code"], messages[-1]["status"], code) == ("too_long", 413, 1008)
    assert ledger(main) == ([(-487, f"realtime:{ready['session_id']}")], NO_ROWS)


@pytest.mark.parametrize("fake, frames, seconds", [
    ({"turns": ("",)}, (LOUD,) * 10, 1.0),
    ({}, (), 0),
    ({"turns": ("",), "commit_empty": True}, (LOUD,) * 10, 1.0),
], ids=["empty-text", "no-audio", "empty-buffer"])
def test_clip_without_speech_is_free(tmp_path, monkeypatch, fake, frames, seconds):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider(**fake))
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            begin(ws)
            assert record_clip(ws, frames, seconds) == ([NO_SPEECH], 1008)
    assert ledger(main) == NOTHING_SAVED


def test_app_that_never_starts_times_out(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    monkeypatch.setattr(realtime, "START_TIMEOUT_SECONDS", 0.2)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            assert read_until_close(ws) == ([{"type": "error", "status": 408, "code": "timeout",
                                              "detail": "The app did not start the recording."}], 1008)
    assert ledger(main) == NOTHING_SAVED


def test_app_that_stops_sending_audio_times_out(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    monkeypatch.setattr(realtime, "IDLE_TIMEOUT_SECONDS", 0.5)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            send_frames(ws, (LOUD,) * 10)
            messages, code = read_until_close(ws)
    assert (messages[-1], code) == ({"type": "error", "status": 408, "code": "timeout",
                                     "detail": "The app stopped sending audio."}, 1008)
    assert ledger(main) == ([(-487, f"realtime:{ready['session_id']}")], NO_ROWS)


def test_provider_that_never_finishes_the_clip_times_out(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    provider.hold.clear()
    monkeypatch.setattr(realtime, "COMMIT_TIMEOUT_SECONDS", 0.3)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            messages, code = record_clip(ws)
    assert (messages[-1], code) == (provider_failure(504), 1011)
    assert ledger(main) == ([(-487, f"realtime:{ready['session_id']}")], NO_ROWS)


def test_replay_needs_the_same_settings_and_about_the_same_length(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            begin(ws, language="en")
            done = record_clip(ws)[0][-1]
        def upload_measured(seconds, **fields):
            async def measured(audio):
                return seconds
            monkeypatch.setattr(main, "measure_audio_duration", measured)
            return upload(client, alice, audio_seconds=str(seconds), **fields)
        other_settings = upload_measured(1.0)
        much_longer = upload_measured(10.0, language="en")
        about_the_same = upload_measured(2.5, language="en")
    assert other_settings.status_code == 409
    assert much_longer.status_code == 409
    assert about_the_same.status_code == 200, about_the_same.text
    assert about_the_same.json()["id"] == done["id"]


def test_new_clip_ends_the_one_still_recording(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice, key="clip-1") as first:
            first_ready = begin(first)
            send_frames(first, (LOUD,) * 10)
            wait_until(lambda: provider.sessions[0].audio_bytes == 48_000)
            with connect(client, alice, key="clip-2") as second:
                begin(second)
                first_messages, first_code = read_until_close(first)
                second_messages, second_code = record_clip(second)
        wait_until(lambda: main._realtime_sessions == {})
    assert (first_messages[-1], first_code) == (SUPERSEDED, 1008)
    done = second_messages[-1]
    assert (done["type"], second_code) == ("done", 1000)
    debits, counts = ledger(main)
    assert sorted(debits) == sorted([(-487, f"realtime:{first_ready['session_id']}"),
                                     (-487, f"transcription:{done['id']}")])
    assert counts == ONE_CLIP


def test_new_clip_leaves_a_committed_one_to_finish(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    provider.hold.clear()
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice, key="clip-1") as first:
            begin(first)
            send_frames(first, (LOUD,) * 10)
            commit(first, 1.0)
            assert provider.commit_seen.wait(5)
            with connect(client, alice, key="clip-2") as second:
                begin(second)
                provider.hold.set()
                first_messages, first_code = read_until_close(first)
                second_messages, second_code = record_clip(second)
        wait_until(lambda: main._realtime_sessions == {})
    first_done, second_done = first_messages[-1], second_messages[-1]
    assert (first_done["type"], first_code, second_done["type"], second_code) == ("done", 1000, "done", 1000)
    debits, counts = ledger(main)
    assert sorted(debits) == sorted([(-487, f"transcription:{first_done['id']}"),
                                     (-487, f"transcription:{second_done['id']}")])
    assert counts == {"transcriptions": 2, "credit_reservations": 0, "transcription_requests": 2}


def test_restart_releases_live_holds_and_unfinished_live_keys(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice, key="done-key") as ws:
            begin(ws)
            done = record_clip(ws)[0][-1]
    alice_id, now = user_id(alice), main.utc_now()
    with main.db() as conn:
        for hold in (("live-hold", alice_id, 29_144, "realtime", now), ("upload-hold", alice_id, 20_000, "transcription", now)):
            conn.execute("INSERT INTO credit_reservations (id, user_id, amount_usd_micros, kind, created_at) "
                         "VALUES (?, ?, ?, ?, ?)", hold)
        for request in ((alice_id, "live-key", "live", "live-hold", None, now, 3, LIVE),
                        (alice_id, "upload-key", "upload", "upload-hold", None, now, 2, "gpt-transcribe")):
            conn.execute("INSERT INTO transcription_requests (user_id, request_key, fingerprint, attempt_id, "
                         "transcription_id, updated_at, fingerprint_version, selected_model) "
                         "VALUES (?, ?, ?, ?, ?, ?, ?, ?)", request)
    with TestClient(main.app) as client:
        with main.db() as conn:
            holds = [row[0] for row in conn.execute("SELECT id FROM credit_reservations ORDER BY id")]
            keys = [row[0] for row in conn.execute("SELECT request_key FROM transcription_requests ORDER BY request_key")]
        replay = transcribe_key(client, alice, "done-key")
    assert holds == ["upload-hold"]
    assert keys == ["done-key", "upload-key"]
    assert replay.status_code == 200, replay.text
    assert replay.json()["id"] == done["id"]


def test_catalog_lists_live_models_with_their_price(tmp_path, monkeypatch):
    main = load_realtime_main(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        catalog = client.get("/v1/transcription/models").json()
        live_upload = upload(client, alice, model=LIVE)
    assert catalog["realtime"] == {"available": True, "default_model": LIVE, "models": [
        {"id": LIVE, "name": "GPT Live Transcribe", "recommended": True, "live_only": True,
         "text_timing": "while_speaking", "retires_on": None, "pricing_basis": "audio_minutes",
         "credit_units_per_minute": 29_144, "formatted_per_minute": "29,144 credits/min"},
        {"id": "gpt-transcribe", "name": "GPT Transcribe", "recommended": False, "live_only": False,
         "text_timing": "after_pauses", "retires_on": None, "pricing_basis": "audio_minutes",
         "credit_units_per_minute": 7_715, "formatted_per_minute": "7,715 credits/min"},
    ]}
    # The live-only model is not offered, or accepted, for uploads.
    assert LIVE not in [model["id"] for model in catalog["models"]]
    assert live_upload.status_code == 400
    assert live_upload.json()["detail"] == "Unsupported transcription model: gpt-live-transcribe"


@pytest.mark.parametrize("configured, default", [
    ("gpt-transcribe", "gpt-transcribe"),
    ("whisper-1", LIVE),
    ("", LIVE),
])
def test_owner_chooses_the_default_live_model(tmp_path, monkeypatch, configured, default):
    main = load_realtime_main(tmp_path, monkeypatch, REALTIME_TRANSCRIPTION_MODEL=configured)
    use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        live = client.get("/v1/transcription/models").json()["realtime"]
        with connect(client, alice) as ws:
            ready = begin(ws)
            cancel(ws)
            read_until_close(ws)
    assert live["default_model"] == default
    assert [model["id"] for model in live["models"] if model["recommended"]] == [default]
    assert ready["model"] == default


@pytest.mark.parametrize("env, expected", [
    ({}, (True, LIVE, 8, frozenset(), 30)),
    ({"REALTIME_TRANSCRIPTION_ENABLED": "YES", "MAX_CONCURRENT_REALTIME_SESSIONS": "100",
      "REALTIME_ALLOWED_USER_IDS": " a , b ,"}, (True, LIVE, 32, frozenset({"a", "b"}), 30)),
    ({"REALTIME_TRANSCRIPTION_ENABLED": "false", "MAX_CONCURRENT_REALTIME_SESSIONS": "0",
      "REALTIME_RATE_LIMIT_PER_WINDOW": "5"}, (False, LIVE, 1, frozenset(), 5)),
])
def test_settings_from_the_environment(tmp_path, monkeypatch, env, expected):
    main = load_realtime_main(tmp_path, monkeypatch, **env)
    assert (main.REALTIME_TRANSCRIPTION_ENABLED, main.REALTIME_TRANSCRIPTION_MODEL,
            main.MAX_CONCURRENT_REALTIME_SESSIONS, main.REALTIME_ALLOWED_USER_IDS,
            main.REALTIME_RATE_LIMIT_PER_WINDOW) == expected


def test_logs_leave_out_transcripts_and_keys(tmp_path, monkeypatch, api_logs):
    main = load_realtime_main(tmp_path, monkeypatch)
    use_provider(monkeypatch, FakeProvider(("Distinctive zebra phrase.",)))
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            ready = begin(ws)
            done = record_clip(ws)[0][-1]
    assert done["transcript"] == "Distinctive zebra phrase."
    formatter = main.JsonExtraFormatter()
    lines = [formatter.format(record) for record in api_logs.records]
    assert not any("zebra" in line or "test-openai-key" in line for line in lines)
    [record] = api_logs.named("realtime_completed")
    assert (record.user_id, record.session_id, record.model, record.audio_seconds, record.turns,
            record.cost_usd_micros) == (user_id(alice), ready["session_id"], LIVE, 1.0, 1, 487)


def test_deleted_account_ends_its_session_without_errors(tmp_path, monkeypatch, api_logs):
    main = load_realtime_main(tmp_path, monkeypatch)
    provider = use_provider(monkeypatch, FakeProvider())
    with TestClient(main.app) as client:
        alice = auth(client, "alice")
        fund(client, alice)
        with connect(client, alice) as ws:
            begin(ws)
            send_frames(ws, (LOUD,) * 10)
            wait_until(lambda: provider.session.audio_bytes == 48_000)
            assert client.delete("/v1/account", headers=alice["headers"]).status_code == 200
            cancel(ws)
            messages, code = read_until_close(ws)
        wait_until(lambda: main._realtime_sessions == {})
    assert (messages[-1], code) == (CANCELLED, 1000)
    assert api_logs.named("realtime_release_failed") == []
    [ended] = api_logs.named("realtime_ended")
    assert (ended.code, ended.cost_usd_micros) == ("cancelled", 0)
    assert ledger(main) == NOTHING_SAVED


@pytest.mark.parametrize("base_url, url", [
    ("https://api.openai.com", "wss://api.openai.com/v1/realtime?intent=transcription"),
    ("http://localhost:8080/", "ws://localhost:8080/v1/realtime?intent=transcription"),
    ("https://gateway.example/openai", "wss://gateway.example/openai/v1/realtime?intent=transcription"),
])
def test_realtime_url(base_url, url):
    assert realtime.realtime_url(base_url) == url


@pytest.mark.parametrize("usage, seconds", [
    ({"type": "duration", "seconds": 2.5}, 2.5),
    ({"type": "duration", "seconds": 3}, 3.0),
    ({"type": "duration", "seconds": 10 ** 400}, 0.0),
    ({"type": "duration", "seconds": float("nan")}, 0.0),
    ({"type": "duration", "seconds": float("inf")}, 0.0),
    ({"type": "duration", "seconds": -1}, 0.0),
    ({"type": "duration", "seconds": True}, 0.0),
    ({"type": "tokens", "input_tokens": 10}, 0.0),
    (None, 0.0),
])
def test_duration_seconds(usage, seconds):
    assert realtime.duration_seconds(usage) == seconds


def test_session_update():
    assert realtime.session_update(LIVE, languages=[], keywords=[], prompt=None) == {
        "type": "session.update", "session": {"type": "transcription", "audio": {"input": {
            "format": {"type": "audio/pcm", "rate": 24_000},
            "transcription": {"model": LIVE},
            "turn_detection": None,
        }}},
    }
    hinted = realtime.session_update(LIVE, languages=["zh", "en"], keywords=["VoiceType"], prompt="Mixed speech.")
    assert hinted["session"]["audio"]["input"]["transcription"] == {
        "model": LIVE, "languages": ["zh", "en"], "keywords": ["VoiceType"], "prompt": "Mixed speech."}


def commit_frames(model, frames):
    """The frame numbers after which the server commits a turn, and the detector."""
    settings = realtime.REALTIME_MODELS[model]
    detector = realtime.PauseDetector(settings["pause_commit_ms"], settings["long_turn_seconds"])
    commits = []
    for number, frame in enumerate(frames, 1):
        if detector.feed(frame):
            commits.append(number)
            detector.reset_turn()
    return commits, detector


def alternating(count):
    """100 ms of speech and 100 ms of silence in turn: no pause long enough to end a turn."""
    return [LOUD if number % 2 == 0 else SILENT for number in range(count)]


@pytest.mark.parametrize("model, frames, commits", [
    # gpt-transcribe writes text only for committed audio, so it commits at 700 ms pauses.
    ("gpt-transcribe", [LOUD] * 10 + [SILENT] * 10, [17]),
    ("gpt-transcribe", [LOUD] * 10 + [SILENT] * 30, [17]),
    # gpt-live-transcribe writes as it hears, so only long turns are committed:
    ("gpt-live-transcribe", [LOUD] * 10 + [SILENT] * 20, []),
    ("gpt-live-transcribe", alternating(300), []),
    # at a 250 ms pause after 30 s,
    ("gpt-live-transcribe", alternating(300) + [SILENT] * 5, [302]),
    # or at 60 s.
    ("gpt-live-transcribe", alternating(700), [600]),
    ("gpt-live-transcribe", [SILENT] * 700, [600]),
    # A steady tone becomes the noise floor, so it counts as a pause.
    ("gpt-live-transcribe", [LOUD] * 400, [300]),
])
def test_pause_detector_commits(model, frames, commits):
    assert commit_frames(model, frames)[0] == commits


def test_pause_detector_tail():
    commits, detector = commit_frames(LIVE, [LOUD] * 10 + [SILENT] * 20)
    assert commits == [] and detector.tail_has_sound
    assert detector.turn_seconds == pytest.approx(3.0)
    # Only silence after the last turn: the server clears it instead of committing.
    commits, detector = commit_frames("gpt-transcribe", [LOUD] * 10 + [SILENT] * 10)
    assert commits == [17] and not detector.tail_has_sound
    assert detector.turn_seconds == pytest.approx(0.3)
    # Quiet speech after a pause is not speech, but is still sent for transcription.
    commits, detector = commit_frames("gpt-transcribe", [SILENT] * 5 + [QUIET] * 3)
    assert commits == [] and detector.tail_has_sound
    assert detector.speech_seconds == 0
    assert detector.sound_seconds == pytest.approx(0.3)


@pytest.mark.parametrize("pieces, text", [
    (["Hello there.", "How are you?"], "Hello there. How are you?"),
    (["你好。", "今天天气不错"], "你好。今天天气不错"),
    (["我们", "开会"], "我们开会"),
    (["Wait", ", what?"], "Wait, what?"),
    ([" ", "One", "", "two "], "One two"),
    (["(x", ")"], "(x)"),
    (["(", "x)"], "(x)"),
])
def test_join_turns(pieces, text):
    assert realtime.join_turns(pieces) == text


def test_transcript_assembler_waits_for_every_committed_turn():
    text = realtime.TranscriptAssembler()
    text.commits_sent = 2
    text.committed("a")
    text.committed("b")
    text.completed("b", "second", 1.0)
    assert not text.all_done()
    text.completed("a", "first", 2.0)
    assert text.all_done()
    assert (text.final_text(), text.usage_seconds) == ("first second", 3.0)
    long = realtime.TranscriptAssembler()
    long.delta("a", "x" * 600)
    assert long.preview() == ("x" * 500, True)


@pytest.mark.parametrize("model, seconds, minimum, cost", [
    (LIVE, 60, True, 29_144),
    (LIVE, 1, True, 487),
    (LIVE, 0.5, True, 487),
    (LIVE, 60.1, True, 29_193),
    (LIVE, 0, False, 0),
    (LIVE, 0.1, False, 50),
    (LIVE, 1.0, False, 487),
    ("gpt-transcribe", 60, True, 7_715),
    ("gpt-transcribe", 3.0, True, 386),
    ("gpt-transcribe", 2.0, True, 258),
])
def test_realtime_cost(tmp_path, monkeypatch, model, seconds, minimum, cost):
    main = load_realtime_main(tmp_path, monkeypatch)
    assert main.realtime_cost(model, seconds, minimum=minimum) == cost
