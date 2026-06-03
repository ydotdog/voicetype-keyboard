# VoiceType Keyboard

VoiceType is a pay-as-you-go iOS speech-to-text keyboard. The containing app handles recording, Sign in with Apple, StoreKit credit packs, and server-backed transcription. The keyboard extension stays small: it inserts the latest transcript from the shared app group and opens the app when the user wants to record.

## Why the flow is split

Apple's custom keyboard sandbox does not allow microphone access, and network/full-access keyboards carry extra review and trust obligations. This v1 keeps microphone capture and billing inside the containing app, then syncs completed transcripts to the keyboard through the app group.

## Product model

- No subscriptions.
- Users buy consumable credit packs with StoreKit.
- Credits are stored server-side as USD micros and never expire.
- Each transcription debits the user's balance according to the configured model price.
- OpenAI API keys stay on the backend only.

## Repo layout

- `VoiceType/`: SwiftUI containing app.
- `VoiceTypeKeyboard/`: iOS custom keyboard extension.
- `Shared/`: shared constants, DTOs, and app-group transcript storage.
- `backend/`: FastAPI backend for Apple auth, credit ledger, StoreKit transaction intake, and OpenAI transcription.
- `StoreKit/Products.storekit`: local StoreKit testing products.

## Local backend

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn main:app --reload
```

Required production env vars:

- `OPENAI_API_KEY`
- `JWT_SECRET`
- `APPLE_CLIENT_ID`, normally the app bundle id `com.kyleqi.voicetype`

Useful development env vars:

- `APPLE_AUTH_DEV_BYPASS=true` accepts identity tokens starting with `dev:`.
- `DATABASE_PATH=./voicetype.sqlite3`
- `OPENAI_TRANSCRIBE_MODEL=gpt-4o-mini-transcribe`

## iOS project

```bash
xcodegen generate
open VoiceType.xcodeproj
```

Use the `VoiceType` scheme. For simulator testing against the backend running on the Mac, keep `VOICETYPE_BACKEND_URL` as `http://127.0.0.1:8000`.

## App Store setup

1. Enable App Groups for the app and keyboard: `group.com.kyleqi.voicetype`.
2. Enable Sign in with Apple for the app target.
3. Create consumable IAP products matching `StoreKit/Products.storekit`.
4. Configure the backend product map before shipping.
5. Replace the development StoreKit transaction decoding path with App Store Server API / signed transaction verification before accepting production credit purchases.

## Source notes

- Existing transcription inspiration came from the Memory Recorder backend `/v1/memories/from-audio` and iOS `RecordingController` / multipart upload client.
- Apple documents that custom keyboards cannot use microphone access in the extension and require care around open access.
- OpenAI's current speech-to-text models include `gpt-4o-mini-transcribe` on `v1/audio/transcriptions`, priced by audio input/output tokens.
