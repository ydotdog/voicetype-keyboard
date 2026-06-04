# Release Checklist

## Apple Developer

- Create or confirm App ID `com.kyleqi.voicetype`.
- Create or confirm App Extension ID `com.kyleqi.voicetype.keyboard`.
- Enable Sign in with Apple on the containing app.
- Enable App Groups on both targets.
- Add App Group `group.com.kyleqi.voicetype` to both targets.
- Confirm the keyboard extension is embedded in the containing app.
- Keep `RequestsOpenAccess=true` for the keyboard extension.

## App Store Connect

- Create the app record for bundle id `com.kyleqi.voicetype`.
- Create consumable IAP products:
  - `com.kyleqi.voicetype.credits.small`, reference name `$1 Credit`, USD 1.00.
  - `com.kyleqi.voicetype.credits.medium`, reference name `$5 Credit`, USD 5.00.
  - `com.kyleqi.voicetype.credits.large`, reference name `$20 Credit`, USD 20.00.
- Match product display names and credit pack sizes with backend `CREDIT_PRODUCTS_JSON` if changed.
- Add screenshots and review notes explaining why the keyboard requires Full Access: it reads the latest transcript from the app's shared container.
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
- Archive the `VoiceType` scheme.
- Upload through Xcode Organizer or an App Store Connect API-based CI lane.
- Test on device:
  - Sign in with Apple succeeds.
  - StoreKit sandbox purchase grants credit.
  - Zero-credit transcription returns an insufficient-credit message.
  - Recording with credit creates a transcript and debits balance.
  - Latest transcript appears in the keyboard after Full Access is enabled.

## Launch Monitoring

- Alert on backend 5xx rate.
- Alert on StoreKit verification failures.
- Track purchase grant count and total granted credits.
- Track transcription cost by model and provider account.
- Track insufficient-credit responses.
- Track OpenAI latency and error rate.
