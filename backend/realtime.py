"""Live transcription relay for OpenAI Realtime transcription sessions.

The app streams 24 kHz PCM over our WebSocket while it records. This module
forwards the audio with the server's provider key and sends back the text
heard so far. main.py owns accounts, credit holds and request keys.
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import math
import sys
import time
from array import array
from contextlib import asynccontextmanager
from dataclasses import dataclass
from operator import mul
from typing import Any, AsyncIterator, Awaitable, Callable, Optional

logger = logging.getLogger("voicetype.api")

PROTOCOL = "voicetype.realtime.v1"
AUDIO_FORMAT = "pcm_s16le_24000_mono"
SAMPLE_RATE = 24_000
BYTES_PER_SECOND = SAMPLE_RATE * 2
MAX_FRAME_BYTES = 32 * 1024
MAX_TEXT_MESSAGE_CHARS = 32 * 1024
MAX_AUDIO_SECONDS = 600
# The app sends 100 ms frames as it records, after one burst of what it
# buffered while connecting. Faster input is not a recording.
INGEST_RATE = 1.5
INGEST_BURST_SECONDS = 15
# Audio held while the provider session starts.
MAX_PENDING_SECONDS = 20
START_TIMEOUT_SECONDS = 10
UPSTREAM_READY_TIMEOUT_SECONDS = 10
IDLE_TIMEOUT_SECONDS = 15
SESSION_TIMEOUT_SECONDS = MAX_AUDIO_SECONDS + 60
COMMIT_TIMEOUT_SECONDS = 30
# Recorded audio the app may have failed to send (a late capture start or a
# dropped frame) before the live result no longer stands for the recording.
MISSING_AUDIO_TOLERANCE_SECONDS = 1.0
PARTIAL_INTERVAL_SECONDS = 0.25
PREVIEW_CHARS = 500

# Models a transcription session accepts. pause_commit_ms commits the buffer
# at pauses for models that only write text for committed audio; every model
# commits long turns so the text after stopping arrives quickly.
REALTIME_MODELS = {
    "gpt-live-transcribe": {"text_timing": "while_speaking", "pause_commit_ms": None, "long_turn_seconds": 30},
    "gpt-transcribe": {"text_timing": "after_pauses", "pause_commit_ms": 700, "long_turn_seconds": 20},
}


class RealtimeError(Exception):
    """Ends a live session. The app then uploads the recording with the same key."""

    def __init__(self, code: str, status: int, detail: str, *, retry_after: Optional[int] = None) -> None:
        super().__init__(detail)
        self.code = code
        self.status = status
        self.detail = detail
        self.retry_after = retry_after

    def payload(self) -> dict[str, Any]:
        body: dict[str, Any] = {"type": "error", "status": self.status, "code": self.code, "detail": self.detail}
        if self.retry_after:
            body["retry_after"] = self.retry_after
        return body


def protocol_error(detail: str) -> RealtimeError:
    return RealtimeError("protocol_error", 400, detail)


def provider_error(status: int = 502) -> RealtimeError:
    return RealtimeError("provider_error", status, "Live transcription was interrupted.")


def superseded_error() -> RealtimeError:
    return RealtimeError("superseded", 409, "A newer request is handling this recording.")


def too_long_error() -> RealtimeError:
    return RealtimeError("too_long", 413, f"A recording must be at most {MAX_AUDIO_SECONDS // 60} minutes.")


def realtime_url(base_url: str) -> str:
    base = base_url.rstrip("/")
    if base.startswith("https://"):
        base = "wss://" + base[len("https://"):]
    elif base.startswith("http://"):
        base = "ws://" + base[len("http://"):]
    return f"{base}/v1/realtime?intent=transcription"


def session_update(model: str, *, languages: list[str], keywords: list[str], prompt: Optional[str]) -> dict[str, Any]:
    transcription: dict[str, Any] = {"model": model}
    # As with file uploads to these models, languages replaces language.
    if languages:
        transcription["languages"] = languages
    if keywords:
        transcription["keywords"] = keywords
    if prompt:
        transcription["prompt"] = prompt
    return {"type": "session.update", "session": {"type": "transcription", "audio": {"input": {
        "format": {"type": "audio/pcm", "rate": SAMPLE_RATE},
        "transcription": transcription,
        # We commit turns ourselves, so no audio is dropped as silence.
        "turn_detection": None,
    }}}}


@asynccontextmanager
async def open_upstream(url: str, api_key: str) -> AsyncIterator[Any]:
    from websockets.asyncio.client import connect

    async with connect(
        url, additional_headers={"Authorization": f"Bearer {api_key}"}, open_timeout=UPSTREAM_READY_TIMEOUT_SECONDS,
        max_size=4 * 1024 * 1024, compression=None, ping_interval=20, ping_timeout=20, proxy=None,
    ) as upstream:
        yield upstream


def duration_seconds(usage: Any) -> float:
    if isinstance(usage, dict) and usage.get("type") == "duration":
        value = usage.get("seconds")
        # The range also leaves out NaN, infinity and integers too large for a float.
        if isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value <= sys.float_info.max:
            return float(value)
    return 0.0


class PauseDetector:
    """Finds pauses in 16-bit PCM by comparing loudness with a running noise floor."""

    WINDOW_BYTES = SAMPLE_RATE // 50 * 2
    WINDOW_SECONDS = 0.02
    MIN_SPEECH_RMS = 400.0
    SPEECH_OVER_FLOOR = 2.5
    # A lower bar for the audio after the last pause, so quiet speech there
    # is still transcribed rather than cleared.
    MIN_SOUND_RMS = 150.0
    SOUND_OVER_FLOOR = 1.5

    def __init__(self, pause_ms: Optional[int], long_turn_seconds: float) -> None:
        self.pause_seconds = pause_ms / 1000 if pause_ms else None
        self.long_turn_seconds = long_turn_seconds
        self.noise_floor = 150.0
        self._carry = b""
        self.reset_turn()

    def reset_turn(self) -> None:
        self.turn_bytes = 0
        self.speech_seconds = 0.0
        self.sound_seconds = 0.0
        self.silence_run = 0.0

    @property
    def turn_seconds(self) -> float:
        return self.turn_bytes / BYTES_PER_SECOND

    @property
    def tail_has_sound(self) -> bool:
        return self.sound_seconds >= 0.1

    def feed(self, frame: bytes) -> bool:
        """True when the turn should be committed after this frame."""
        self.turn_bytes += len(frame)
        data = self._carry + frame
        usable = len(data) - len(data) % self.WINDOW_BYTES
        self._carry = data[usable:]
        for offset in range(0, usable, self.WINDOW_BYTES):
            self._observe(self._rms(data[offset:offset + self.WINDOW_BYTES]))
        turn = self.turn_seconds
        if turn >= 2 * self.long_turn_seconds:
            return True
        if self.speech_seconds <= 0:
            return False
        if (self.pause_seconds and self.speech_seconds >= 0.3 and turn >= 1.0
                and self.silence_run >= self.pause_seconds):
            return True
        return turn >= self.long_turn_seconds and self.silence_run >= 0.25

    @staticmethod
    def _rms(window: bytes) -> float:
        samples = array("h")
        samples.frombytes(window)
        if sys.byteorder == "big":
            samples.byteswap()
        part = samples[::4]
        return math.sqrt(sum(map(mul, part, part)) / len(part))

    def _observe(self, rms: float) -> None:
        if rms >= max(self.MIN_SOUND_RMS, self.noise_floor * self.SOUND_OVER_FLOOR):
            self.sound_seconds += self.WINDOW_SECONDS
        speech = rms >= max(self.MIN_SPEECH_RMS, self.noise_floor * self.SPEECH_OVER_FLOOR)
        if speech:
            self.speech_seconds += self.WINDOW_SECONDS
            self.silence_run = 0.0
        else:
            self.silence_run += self.WINDOW_SECONDS
        # Falls quickly in quiet moments; rises slowly to steady background noise.
        rate = 0.1 if rms < self.noise_floor else (0.004 if speech else 0.02)
        self.noise_floor += (rms - self.noise_floor) * rate


def _is_cjk(ch: str) -> bool:
    code = ord(ch)
    return (0x3000 <= code <= 0x30FF or 0x3400 <= code <= 0x4DBF or 0x4E00 <= code <= 0x9FFF
            or 0xF900 <= code <= 0xFAFF or 0xFF00 <= code <= 0xFFEF)


def join_turns(pieces: list[str]) -> str:
    """Joins turn texts, without spaces between Chinese or Japanese text."""
    text = ""
    for piece in pieces:
        piece = piece.strip()
        if not piece:
            continue
        left, right = (text[-1], piece[0]) if text else ("", "")
        if text and not (
            (_is_cjk(left) and _is_cjk(right)) or left in "([{（【「『《，。！？；：、"
            or right in ",.!?;:%)]}，。！？；：、）】」』》"
        ):
            text += " "
        text += piece
    return text


class TranscriptAssembler:
    """Collects text per committed turn. Turns may finish out of order."""

    def __init__(self) -> None:
        self.order: list[str] = []
        self.deltas: dict[str, str] = {}
        self.finished: dict[str, str] = {}
        self.committed_items: set[str] = set()
        self.commits_sent = 0
        self.acks = 0
        self.usage_seconds = 0.0
        self.version = 0
        self._preview: tuple[int, tuple[str, bool]] = (-1, ("", False))

    def _see(self, item: str) -> None:
        if item not in self.deltas and item not in self.finished and item not in self.committed_items:
            self.order.append(item)

    def committed(self, item: Optional[str]) -> None:
        self.acks += 1
        if item is not None:
            self._see(item)
            self.committed_items.add(item)

    def commit_empty(self) -> None:
        self.acks += 1

    def delta(self, item: str, text: str) -> None:
        self._see(item)
        self.deltas[item] = self.deltas.get(item, "") + text
        self.version += 1

    def completed(self, item: str, transcript: str, seconds: float) -> None:
        self._see(item)
        self.finished[item] = transcript
        self.usage_seconds += seconds
        self.version += 1

    def all_done(self) -> bool:
        return self.acks >= self.commits_sent and self.committed_items <= set(self.finished)

    def open_item_has_text(self) -> bool:
        return any(text.strip() for item, text in self.deltas.items()
                   if item not in self.committed_items and item not in self.finished)

    def preview(self) -> tuple[str, bool]:
        if self._preview[0] != self.version:
            text = join_turns([self.finished.get(item, self.deltas.get(item, "")) for item in self.order])
            self._preview = (self.version, (text[-PREVIEW_CHARS:], len(text) > PREVIEW_CHARS))
        return self._preview[1]

    def final_text(self) -> str:
        return join_turns([self.finished[item] for item in self.order if item in self.finished])


@dataclass
class RelayResult:
    text: str
    forwarded_seconds: float
    usage_seconds: float
    turns: int


class RealtimeRelay:
    """Relays one clip between the app's WebSocket and a provider session."""

    def __init__(self, websocket: Any, *, model: str, upstream_url: str, api_key: str, configuration: dict[str, Any],
                 ready_payload: dict[str, Any], reserve: Callable[[float], Awaitable[None]],
                 on_commit: Callable[[], Awaitable[None]],
                 server_stopping: Callable[[], bool] = lambda: False) -> None:
        settings = REALTIME_MODELS[model]
        self.websocket = websocket
        self.upstream_url = upstream_url
        self.api_key = api_key
        self.configuration = configuration
        self.ready_payload = ready_payload
        # reserve(seconds) runs before audio up to that length is forwarded and
        # on_commit when the app ends the clip; both raise RealtimeError to end
        # the session.
        self.reserve = reserve
        self.on_commit = on_commit
        # True once the server has been told to stop.
        self.server_stopping = server_stopping
        self.inbox: asyncio.Queue = asyncio.Queue()
        self.detector = PauseDetector(settings["pause_commit_ms"], settings["long_turn_seconds"])
        self.text = TranscriptAssembler()
        self.upstream: Any = None
        self.ready = False
        self.committed = False
        self.final_commit_sent = False
        self.client_gone = False
        self.received_bytes = 0
        self.forwarded_bytes = 0
        self.pending: list[bytes] = []
        self.pending_bytes = 0
        self.started = time.monotonic()
        self.last_client_message = self.started
        self.committed_at = 0.0
        self.last_partial: tuple[str, bool] = ("", False)
        self.last_partial_at = 0.0

    @property
    def forwarded_seconds(self) -> float:
        return self.forwarded_bytes / BYTES_PER_SECOND

    def stop(self, error: RealtimeError) -> None:
        self.inbox.put_nowait(("error", error))

    async def run(self) -> RelayResult:
        tasks = [asyncio.ensure_future(self._read_client()), asyncio.ensure_future(self._run_upstream())]
        try:
            return await self._relay()
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _read_client(self) -> None:
        received = 0
        while True:
            try:
                message = await self.websocket.receive()
            except Exception:
                # The connection failed without a close frame.
                message = {"type": "websocket.disconnect", "code": 1006}
            frame = message.get("bytes") if message["type"] == "websocket.receive" else None
            if frame is not None:
                received += len(frame)
                allowed = (INGEST_RATE * (time.monotonic() - self.started) + INGEST_BURST_SECONDS) * BYTES_PER_SECOND
                if not frame or len(frame) % 2 or len(frame) > MAX_FRAME_BYTES:
                    self.inbox.put_nowait(("error", protocol_error("Audio frames must be 16-bit PCM up to 32 KB.")))
                    return
                if received > MAX_AUDIO_SECONDS * BYTES_PER_SECOND + MAX_FRAME_BYTES:
                    self.inbox.put_nowait(("error", too_long_error()))
                    return
                if received > allowed:
                    self.inbox.put_nowait(("error", protocol_error("Audio is arriving faster than it can be recorded.")))
                    return
            self.inbox.put_nowait(("client", message))
            if message["type"] == "websocket.disconnect":
                return

    async def _run_upstream(self) -> None:
        try:
            async with open_upstream(self.upstream_url, self.api_key) as upstream:
                await upstream.send(json.dumps(self.configuration))
                self.upstream = upstream
                async for raw in upstream:
                    self.inbox.put_nowait(("upstream", raw))
            self.inbox.put_nowait(("upstream_closed", None))
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.inbox.put_nowait(("upstream_closed", exc))

    def _next_deadline(self) -> tuple[float, Optional[Callable[[], RealtimeError]]]:
        deadlines: list[tuple[float, Optional[Callable[[], RealtimeError]]]] = []
        if not self.ready:
            deadlines.append((self.started + UPSTREAM_READY_TIMEOUT_SECONDS, lambda: provider_error(503)))
        if self.committed:
            deadlines.append((self.committed_at + COMMIT_TIMEOUT_SECONDS, lambda: provider_error(504)))
        else:
            deadlines.append((self.last_client_message + IDLE_TIMEOUT_SECONDS,
                              lambda: RealtimeError("timeout", 408, "The app stopped sending audio.")))
            deadlines.append((self.started + SESSION_TIMEOUT_SECONDS, too_long_error))
        if not self.client_gone and self.text.preview() != self.last_partial:
            deadlines.append((self.last_partial_at + PARTIAL_INTERVAL_SECONDS, None))
        return min(deadlines, key=lambda item: item[0])

    async def _relay(self) -> RelayResult:
        while True:
            deadline, expired = self._next_deadline()
            try:
                kind, value = await asyncio.wait_for(self.inbox.get(), max(0.0, deadline - time.monotonic()))
            except asyncio.TimeoutError:
                if expired is not None:
                    raise expired()
                await self._send_partial()
                continue
            if kind == "client":
                await self._on_client(value)
            elif kind == "upstream":
                await self._on_upstream(value)
            elif kind == "upstream_closed":
                if value is not None:
                    logger.warning("realtime_upstream_closed", extra={"error": value.__class__.__name__})
                raise provider_error()
            else:
                raise value
            if self.final_commit_sent and self.text.all_done():
                return RelayResult(self.text.final_text(), self.forwarded_seconds, self.text.usage_seconds,
                                   len(self.text.finished))
            if (not self.client_gone and self.text.preview() != self.last_partial
                    and time.monotonic() >= self.last_partial_at + PARTIAL_INTERVAL_SECONDS):
                await self._send_partial()

    async def _send_partial(self) -> None:
        self.last_partial = self.text.preview()
        self.last_partial_at = time.monotonic()
        text, truncated = self.last_partial
        await self._send_client({"type": "partial", "text": text, "truncated": truncated})

    async def _send_client(self, payload: dict[str, Any]) -> None:
        if self.client_gone:
            return
        try:
            await self.websocket.send_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        except Exception:
            # A clip committed before the app left still finishes and is saved.
            self.client_gone = True

    async def _send_upstream(self, event: dict[str, Any]) -> None:
        try:
            await self.upstream.send(json.dumps(event))
        except Exception as exc:
            raise provider_error() from exc

    async def _on_client(self, message: dict[str, Any]) -> None:
        if message["type"] == "websocket.disconnect":
            self.client_gone = True
            # Uvicorn closes each connection with 1012 as it shuts down. An app
            # can send 1012 itself, so the code counts only while stopping.
            if message.get("code") == 1012 and self.server_stopping():
                raise RealtimeError("server_restarting", 503, "The server is restarting.")
            if not self.committed:
                raise RealtimeError("disconnected", 499, "The app disconnected before the recording ended.")
            return
        self.last_client_message = time.monotonic()
        frame = message.get("bytes")
        if frame is not None:
            await self._on_audio(frame)
            return
        text = message.get("text")
        try:
            data = json.loads(text) if isinstance(text, str) and len(text) <= MAX_TEXT_MESSAGE_CHARS else None
        except (ValueError, RecursionError):
            data = None
        kind = data.get("type") if isinstance(data, dict) else None
        if kind == "commit":
            await self._on_commit(data)
        elif kind == "cancel":
            raise RealtimeError("cancelled", 499, "The recording was cancelled.")
        else:
            raise protocol_error("Unexpected message.")

    async def _on_audio(self, frame: bytes) -> None:
        if self.committed:
            # Not part of the clip the app committed.
            return
        if self.received_bytes + len(frame) > MAX_AUDIO_SECONDS * BYTES_PER_SECOND:
            raise too_long_error()
        self.received_bytes += len(frame)
        if self.ready:
            await self._forward(frame)
            return
        if self.pending_bytes + len(frame) > MAX_PENDING_SECONDS * BYTES_PER_SECOND:
            raise provider_error(503)
        self.pending.append(frame)
        self.pending_bytes += len(frame)

    async def _forward(self, frame: bytes) -> None:
        await self.reserve((self.forwarded_bytes + len(frame)) / BYTES_PER_SECOND)
        end_turn = self.detector.feed(frame)
        await self._send_upstream({"type": "input_audio_buffer.append", "audio": base64.b64encode(frame).decode("ascii")})
        self.forwarded_bytes += len(frame)
        if end_turn:
            await self._commit_turn()

    async def _commit_turn(self) -> None:
        await self._send_upstream({"type": "input_audio_buffer.commit"})
        self.text.commits_sent += 1
        self.detector.reset_turn()

    async def _on_commit(self, data: dict[str, Any]) -> None:
        if self.committed:
            raise protocol_error("The recording was already committed.")
        seconds = data.get("audio_seconds")
        # The range also refuses NaN, infinity and integers too large for a float.
        if (isinstance(seconds, bool) or not isinstance(seconds, (int, float))
                or not 0 <= seconds <= MAX_AUDIO_SECONDS + 1):
            raise protocol_error("audio_seconds must be the recording length in seconds.")
        if self.received_bytes / BYTES_PER_SECOND < seconds - MISSING_AUDIO_TOLERANCE_SECONDS:
            raise RealtimeError("fallback_required", 409, "Live audio is incomplete. Upload the recording instead.")
        await self.on_commit()
        self.committed = True
        self.committed_at = time.monotonic()
        if self.ready:
            await self._final_commit()

    async def _final_commit(self) -> None:
        self.final_commit_sent = True
        tail = self.detector.turn_seconds
        if (self.detector.tail_has_sound or self.text.open_item_has_text()
                or (self.text.commits_sent == 0 and tail >= 0.1)):
            await self._commit_turn()
        elif tail > 0:
            # Only silence after the last turn.
            await self._send_upstream({"type": "input_audio_buffer.clear"})
            self.detector.reset_turn()

    async def _become_ready(self) -> None:
        self.ready = True
        await self._send_client({"type": "ready", **self.ready_payload})
        frames, self.pending, self.pending_bytes = self.pending, [], 0
        for frame in frames:
            await self._forward(frame)
        if self.committed:
            await self._final_commit()

    async def _on_upstream(self, raw: Any) -> None:
        try:
            event = json.loads(raw)
        except (TypeError, ValueError, RecursionError):
            event = None
        if not isinstance(event, dict):
            raise provider_error()
        kind = event.get("type")
        item = event.get("item_id") if isinstance(event.get("item_id"), str) else None
        if kind in ("session.updated", "transcription_session.updated"):
            if not self.ready:
                await self._become_ready()
        elif kind == "input_audio_buffer.committed":
            self.text.committed(item)
        elif kind == "conversation.item.input_audio_transcription.delta":
            if isinstance(event.get("delta"), str):
                self.text.delta(item or "", event["delta"])
        elif kind == "conversation.item.input_audio_transcription.completed":
            if not isinstance(event.get("transcript"), str):
                raise provider_error()
            self.text.completed(item or "", event["transcript"], duration_seconds(event.get("usage")))
        elif kind in ("conversation.item.input_audio_transcription.failed", "error"):
            error = event.get("error") if isinstance(event.get("error"), dict) else {}
            if kind == "error" and error.get("code") == "input_audio_buffer_commit_empty":
                self.text.commit_empty()
                return
            # Codes only: provider messages can quote the request.
            logger.warning("realtime_provider_error", extra={
                "event_type": kind, "error_type": error.get("type"), "error_code": error.get("code")})
            raise provider_error()
