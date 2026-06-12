# Release Checklist

## Apple Developer

- Create or confirm App ID `com.kyleqi.voicetype`.
- Create or confirm App Extension ID `com.kyleqi.voicetype.keyboard`.
- Enable Sign in with Apple on the containing app.
- Create a **Sign in with Apple key** (Keys → enable Sign in with Apple), download
  the `.p8`, and note the Key ID and Team ID. The backend needs these to revoke the
  Apple token grant on account deletion (Guideline 5.1.1(v)).
- Enable App Groups on both targets.
- Add App Group `group.com.kyleqi.voicetype` to both targets.
- Confirm the keyboard extension is embedded in the containing app.
- Keep `RequestsOpenAccess=true` for the keyboard extension.

## App Store Connect

- Create the app record for bundle id `com.kyleqi.voicetype`.
- Create consumable IAP products:
  - `com.kyleqi.voicetype.credits.small`, reference name `990,000 Credits`, USD 0.99.
  - `com.kyleqi.voicetype.credits.medium`, reference name `4,990,000 Credits`, USD 4.99.
  - `com.kyleqi.voicetype.credits.large`, reference name `19,990,000 Credits`, USD 19.99.
- The repo includes `scripts/configure_app_store_iaps.py` to create or update the
  products through the App Store Connect API. It auto-discovers
  `~/.appstoreconnect/private_keys/AuthKey_*.p8` when there is exactly one local
  key. After copying the issuer ID from App Store Connect, dry-run first:
  `ASC_ISSUER_ID=<issuer-id> python3 scripts/configure_app_store_iaps.py`, then
  apply with `--apply`.
- Match product display names and credit pack sizes with backend `CREDIT_PRODUCTS_JSON` if changed.
- Add screenshots and paste `docs/APP_REVIEW_NOTES.md` into App Review Information
  (covers Full Access, the audio background mode, the welcome credit for testing,
  account deletion, and how to test the keyboard flow).
- Set the app's Privacy Policy URL to `https://voicetype.y.dog/privacy`.
- Complete the **App Privacy** nutrition label to match the privacy manifest:
  Name (if shared at sign-in), Email Address, User ID, Audio Data, Other User
  Content (transcripts), and Purchase History — all linked to the user, used for
  App Functionality, not used for tracking.
- Confirm account deletion is reachable in-app (Settings → Delete account) for
  Guideline 5.1.1(v).
- Use StoreKit sandbox/TestFlight before production launch.

## Backend

- Deploy the backend from `backend/Dockerfile`.
- Use Postgres through `DATABASE_URL`.
- Configure `JWT_SECRET` with a long random value.
- Configure `OPENAI_API_KEY` only on the backend.
- Configure `OPENAI_TRANSCRIBE_MODEL`, default `gpt-4o-mini-transcribe`.
- Configure `COST_MARKUP_BPS=7143` for standard App Store commission plus 20% profit.
- Configure `APPLE_CLIENT_ID=com.kyleqi.voicetype`.
- Configure `APPLE_BUNDLE_ID=com.kyleqi.voicetype`.
- Configure `APPLE_APP_APPLE_ID` from App Store Connect.
- Configure Sign in with Apple server credentials so account deletion revokes the
  Apple token grant: `APPLE_SIGNIN_TEAM_ID`, `APPLE_SIGNIN_KEY_ID`, and the `.p8`
  via `APPLE_SIGNIN_PRIVATE_KEY` / `_B64` / `_PATH`. (Deletion still works without
  these; the token simply is not revoked.)
- Decide the welcome-credit policy: `SIGNUP_GRANT_ENABLED` (default true) and
  `SIGNUP_GRANT_USD_MICROS` (default 100000 = ~US$0.10). Keep it enabled so App
  Review can test transcription without a purchase.
- Provide Apple root certificates through `APPLE_ROOT_CERTIFICATE_PATHS` or `APPLE_ROOT_CERTIFICATE_PEMS_B64`.
- Keep production StoreKit flags:
  - `STOREKIT_VERIFICATION_MODE=strict`
  - `ALLOW_UNVERIFIED_STOREKIT_JWS=false`
  - `REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN=true`
  - `ALLOW_DEV_CREDIT=false`
- Put the backend behind HTTPS.
- Set request body limits to at least `MAX_AUDIO_BYTES`.
- Enable database backups.

## iOS Build

- Replace Release `VOICETYPE_BACKEND_URL` in `project.yml` with the production HTTPS host.
- Run `xcodegen generate`.
- Archived and uploaded `1.0.0 (1)` on 2026-06-13 through `xcodebuild
  -exportArchive` with App Store Connect upload destination. App Store Connect
  package processing started.
- Test on device:
  - Sign in with Apple succeeds.
  - First sign-in grants the welcome credit (balance is non-zero without a purchase).
  - Settings → Delete account removes the account; signing in again creates a fresh
    account and the protected endpoints reject the old session token.
  - StoreKit sandbox purchase grants credit.
  - Interrupted or unfinished StoreKit purchases are granted after relaunch/sign-in.
  - Zero-credit transcription returns an insufficient-credit message.
  - Recording with credit creates a transcript and debits balance.
  - Failed transcription provider calls do not debit balance.
  - Latest transcript appears in the keyboard after Full Access is enabled.

## Launch Monitoring

- Alert on backend 5xx rate.
- Alert on StoreKit verification failures.
- Track purchase grant count and total granted credits.
- Track transcription cost by model and provider account.
- Track insufficient-credit responses.
- Track OpenAI latency and error rate.
