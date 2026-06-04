# VoiceType Keyboard

VoiceType is a pay-as-you-go iOS speech-to-text keyboard. The containing app owns recording, Sign in with Apple, StoreKit credit packs, and secure backend calls. The keyboard extension stays focused: it inserts the latest transcript from the shared App Group and opens the app when the user wants to record again.

## Product Model

- No subscription.
- Users buy consumable credit packs through StoreKit.
- Credits are stored server-side in retail USD micros and do not expire.
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

- Debug backend URL: `http://192.168.2.63:8000` for local iPhone testing on this network.
- Release backend URL: `https://voicetype.y.dog`.
- App Group: `group.com.kyleqi.voicetype`.
- Bundle IDs: `com.kyleqi.voicetype` and `com.kyleqi.voicetype.keyboard`.

The keyboard extension requests Full Access because it needs to read the latest transcript from the shared App Group container.

## App Store Products

Create consumable In-App Purchase products matching:

- `com.kyleqi.voicetype.credits.small`: `$1 Credit`, USD 1.00
- `com.kyleqi.voicetype.credits.medium`: `$5 Credit`, USD 5.00
- `com.kyleqi.voicetype.credits.large`: `$20 Credit`, USD 20.00

Keep the backend product catalog in sync through `CREDIT_PRODUCTS_JSON` if prices or pack sizes change.

## Current Verification

Verified locally:

- Backend per-user ledger tests pass.
- StoreKit transaction replay is idempotent.
- StoreKit transactions for one user cannot be submitted by another user.
- StoreKit transactions without `appAccountToken` are rejected.
- Existing local SQLite schemas migrate in place.
- Debug and Release iOS builds succeed with the keyboard extension embedded.
