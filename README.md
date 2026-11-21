# VoiceType Keyboard

VoiceType is a pay-as-you-go iOS speech-to-text keyboard. The containing app owns recording, Sign in with Apple, StoreKit credit packs, and secure backend calls. The user turns on the keyboard mic in the containing app, then taps the keyboard in any text field to mark the clip to transcribe and insert. The keyboard extension coordinates with the app through the shared App Group.

## Product Model

- No subscription.
- Users buy consumable credit packs through StoreKit.
- Credits are non-expiring integer units. The current scale is `1 USD = 1,000,000 credits`.
- Every credit/debit is written to a per-user immutable ledger.
- The OpenAI API key is held by the backend only.
- Transcription debits apply the configured retail markup to raw OpenAI model cost.
- StoreKit transactions are verified server-side and bound to the backend user through `appAccountToken`.

## Repo Layout

- `VoiceType/`: SwiftUI containing app.
- `VoiceTypeKeyboard/`: iOS custom keyboard extension.
- `Shared/`: shared DTOs, constants, and App Group transcript storage.
- `backend/`: FastAPI backend for Apple auth, StoreKit verification, credit ledger, and OpenAI transcription.
- `StoreKit/Products.storekit`: local StoreKit testing catalog.
- `docs/ARCHITECTURE.md`: billing and scaling architecture.
- `docs/RELEASE_CHECKLIST.md`: App Store and backend launch checklist.

## Backend

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
uvicorn main:app --reload
```

Run tests:

```bash
cd backend
PYTHONPATH=. .venv/bin/python -m pytest -q
```

From the repo root:

```bash
source backend/.venv/bin/activate
pytest -q backend/tests
```

Production uses `DATABASE_URL` for Postgres. If `DATABASE_URL` is empty, the backend falls back to SQLite for local development.

Important production env vars:

- `OPENAI_API_KEY`
- `JWT_SECRET`
- `DATABASE_URL`
- `APPLE_CLIENT_ID`
- `APPLE_BUNDLE_ID`
- `APPLE_APP_APPLE_ID`
- `APPLE_ROOT_CERTIFICATE_PATHS` or `APPLE_ROOT_CERTIFICATE_PEMS_B64`
- `STOREKIT_VERIFICATION_MODE=strict`
- `ALLOW_UNVERIFIED_STOREKIT_JWS=false`
- `REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN=true`
- `COST_MARKUP_BPS=7143` for standard 30% App Store commission plus 20% profit.

## iOS

```bash
xcodegen generate
open VoiceType.xcodeproj
```

Use the `VoiceType` scheme.

Build settings:

- Debug backend URL: `https://voicetype.y.dog` so device builds use the deployed backend by default.
- Release backend URL: `https://voicetype.y.dog`.
- App Group: `group.com.kyleqi.voicetype`.
- Bundle IDs: `com.kyleqi.voicetype` and `com.kyleqi.voicetype.keyboard`.

The keyboard extension requests Full Access because it needs to read the latest transcript, account balance, and recording bridge state from the shared App Group container. iOS custom keyboard extensions cannot access the microphone directly, so the containing app owns the audio session. Users turn on the keyboard mic in VoiceType first; while the app keeps the audio session alive under the audio background mode, the keyboard sends start/stop clip commands through the shared bridge. Users can choose a recording session length of 5 minutes, 12 hours, or Forever.

## Personalized Dictation

In **Settings → Languages & vocabulary**, choose up to three spoken languages or
leave selection empty for automatic detection. Choose simplified or traditional
Chinese explicitly to control writing style. Chinese punctuation is normalized
without changing protected URLs, email addresses, numbers, filenames, or code.

Add names and places to your personal vocabulary, or use **Edit & teach** in
History to fix a transcript. With **Learn from my corrections** on, VoiceType
suggests the names and terms you changed; a fix for a misheard form that isn't
an everyday word (工月 → 龚玥, Kyle Key → Kyle Qi) also replaces that form, as a
whole word, in new transcripts before they reach History or the keyboard. Tap a
word in Settings to manage the forms it fixes. Vocabulary is stored per account
on the device; the most recent 50 terms accompany transcription requests, while
misheard forms stay on the device. Failed recordings retain their original
hints and model for idempotent retries. Recognition hints improve context but
cannot guarantee every homophone or rare name.

**Settings → Transcription model** lists the models the service offers, with an
estimated price per minute. **Automatic** follows the service default; a model
the service retires falls back to it.

Removing the Live Activity stops the keyboard microphone. The Lock Screen and
expanded Dynamic Island also provide **Turn off mic**. iOS can collapse Dynamic
Island without dismissing an activity; that gesture does not emit a dismissal
callback. See [build 25 notes](docs/DICTATION_25.zh-CN.md) for validation and device
checks.

## Streaming Transcription

After a clip ends, models that support streaming send the text heard so far
while the service transcribes it. Home and a History row being retried show it;
with Full Access, the keyboard previews it in its top row, newest words in view,
without changing its height. The preview is raw provider text. Only the final
transcript, with punctuation normalized and your fixes applied, is saved to
History and inserted, once. whisper-1 cannot stream and returns only the result.

The app adds the form field `stream=true` and `Accept: text/event-stream` to
`POST /v1/transcriptions`. Failures found before transcription starts (sign-in,
validation, balance, a busy server, a request key in use) stay ordinary HTTP
errors. After that the response is `text/event-stream`:

- `event: delta`, `data: {"delta":"…"}`: the next text, in order.
- `event: done`, `data:` the same JSON as a non-streaming response.
- `event: error`, `data: {"status":422,"detail":"…","code":"no_speech"}`: the
  status and body a non-streaming request would have returned.
- `: keepalive` comments every 15 seconds while waiting.

A client that disconnects does not stop the transcription: the service
finishes, charges once and saves the result. The app keeps the clip in History,
and a retry with the same `Idempotency-Key` returns that result without calling
the provider again. On shutdown, streams get 5 seconds to finish; the rest are
cancelled, their hold released and nothing charged. Proxies must pass events
through unbuffered and uncompressed; responses carry
`Cache-Control: no-cache, no-transform` and `X-Accel-Buffering: no`.

An older service ignores `stream` and answers with JSON, which the app uses
without a preview. If a proxy answers the streaming request with 404 or 405,
the app sends a plain upload with the same key. Older apps never ask for a
stream. Deploy the service first so the preview works from the app's release.

## Live Transcription

Settings → Transcription mode & model offers **After recording**, **Streaming**
(the default) and **Live**; the keyboard and Home recording follow the choice.
Live sends a clip's audio while the user speaks, so text appears before they
finish. Its models are `gpt-live-transcribe` (text while speaking) and
`gpt-transcribe` (text after each pause). Audio sent is charged at the live
price per minute, including audio of a clip that is cancelled or doesn't finish.

The app opens a WebSocket to `/v1/realtime/transcriptions` with the
`voicetype.realtime.v1` subprotocol, the sign-in token and the clip's
`Idempotency-Key`, and sends 24 kHz 16-bit mono PCM. It receives `ready`,
`partial`, then `done` (the same JSON as an upload) or `error`. The backend
relays the audio to OpenAI's Realtime API with its own key. Without a `done`,
the app uploads the recording saved on the device with the same key; if the live
session has already finished, the service returns its result without charging
again. In Low Data Mode, or when the service is older or has Live turned off,
the app uploads instead. See `docs/OPERATIONS.zh-CN.md` for configuration and
operations, and `docs/REALTIME_TRANSCRIPTION.zh-CN.md` for the design.

## App Store Products

Create consumable In-App Purchase products matching:

- `com.kyleqi.voicetype.credits.small`: `990,000 Credits`, USD 0.99
- `com.kyleqi.voicetype.credits.medium`: `4,990,000 Credits`, USD 4.99
- `com.kyleqi.voicetype.credits.large`: `19,990,000 Credits`, USD 19.99

Keep the backend product catalog in sync through `CREDIT_PRODUCTS_JSON` if prices or pack sizes change.

## Current Verification

Verified locally:

- Backend per-user ledger tests pass.
- StoreKit transaction replay is idempotent.
- StoreKit transactions for one user cannot be submitted by another user.
- StoreKit transactions without `appAccountToken` are rejected.
- Unfinished StoreKit transactions are replayed to the backend on app launch after sign-in.
- Successful transcriptions debit credit; failed provider calls do not.
- A streamed transcription whose client disconnects is charged once, and a retry with the same key returns the saved result.
- Existing local SQLite schemas migrate in place.
- Debug and Release iOS builds succeed with the keyboard extension embedded.
