# Release Checklist

## Apple Developer

- Create or confirm App ID `com.kyleqi.voicetype`.
- Create or confirm App Extension ID `com.kyleqi.voicetype.keyboard`.
- Enable Sign in with Apple on the containing app.
- Sign in with Apple key is created and deployed to the backend so account
  deletion revokes the Apple token grant (Guideline 5.1.1(v)).
- Enable App Groups on both targets.
- Add App Group `group.com.kyleqi.voicetype` to both targets.
- Confirm the keyboard extension is embedded in the containing app.
- Keep `RequestsOpenAccess=true` for the keyboard extension.

## App Store Connect

- Create the app record for bundle id `com.kyleqi.voicetype`.
- Consumable IAP products are created and submitted with version `1.0`
  (`WAITING_FOR_REVIEW`):
  - `com.kyleqi.voicetype.credits.small`, reference name `990,000 Credits`, USD 0.99.
  - `com.kyleqi.voicetype.credits.medium`, reference name `4,990,000 Credits`, USD 4.99.
  - `com.kyleqi.voicetype.credits.large`, reference name `19,990,000 Credits`, USD 19.99.
- The repo includes `scripts/configure_app_store_iaps.py` to create or update
  the products through the App Store Connect API. It auto-discovers
  `~/.appstoreconnect/private_keys/AuthKey_*.p8` when there is exactly one local
  key. Dry-run first with `ASC_ISSUER_ID=<issuer-id> python3
  scripts/configure_app_store_iaps.py`, then apply with `--apply`.
- Match product display names and credit pack sizes with backend `CREDIT_PRODUCTS_JSON` if changed.
- Confirm the Paid Apps Agreement, bank account, U.S. tax form, and Digital
  Services Act compliance are `Active` in App Store Connect Business.
- App Store version `1.0` is linked to uploaded build `1.0.0 (9)`.
- App Store version `1.0` has the three consumable credit products selected in
  `In-App Purchases and Subscriptions`.
- English description, keywords, support URL, marketing URL, privacy policy URL,
  subtitle, and promotional text are set.
- iPhone 6.7-inch and iPad Pro 12.9-inch screenshots are uploaded and processed.
- Age rating declaration is set.
- Primary category is set to Productivity.
- App Privacy nutrition label is published and matches the privacy manifest:
  Name (if shared at sign-in), Email Address, User ID, Audio Data, Other User
  Content (transcripts), and Purchase History — all linked to the user, used for
  App Functionality, not used for tracking.
- App Review contact phone number is set, and `docs/APP_REVIEW_NOTES.md` has
  been pasted into App Review Information.
- Confirm account deletion is reachable in-app (Settings → Delete account) for
  Guideline 5.1.1(v).
- StoreKit sandbox/TestFlight validation passed for build `9`.
- Version `1.0` was submitted for App Review on 2026-06-16. After a
  keyboard-mic stale recorder bug was reproduced in build `9`, release was
  changed back to manual so build `9` cannot automatically go live if approved.

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
- Sign in with Apple server credentials are configured so account deletion
  revokes the Apple token grant: `APPLE_SIGNIN_TEAM_ID`, `APPLE_SIGNIN_KEY_ID`,
  and the `.p8` via `APPLE_SIGNIN_PRIVATE_KEY` / `_B64` / `_PATH`.
- Decide the welcome-credit policy: `SIGNUP_GRANT_ENABLED` (default true) and
  `SIGNUP_GRANT_USD_MICROS` (default 100000 = ~US$0.10). Keep it enabled so App
  Review can test transcription without a purchase.
- Provide Apple root certificates through `APPLE_ROOT_CERTIFICATE_PATHS` or `APPLE_ROOT_CERTIFICATE_PEMS_B64`.
- Keep production StoreKit flags:
  - `STOREKIT_VERIFICATION_MODE=strict`
  - `ALLOW_UNVERIFIED_STOREKIT_JWS=false`
  - `REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN=true`
  - `ALLOW_DEV_CREDIT=false`
- StoreKit verification accepts the transaction's own environment first, then the
  configured environment, then Sandbox and Production, while keeping strict
  signature verification and `appAccountToken` matching enabled.
- During App Review and the next public release candidate, keep
  `STOREKIT_ACCEPTED_ENVIRONMENTS=SANDBOX,PRODUCTION` so reviewer sandbox
  transactions and public production transactions both grant credit. After the
  public launch is stable, switch it to `PRODUCTION` and restart the backend.
- Put the backend behind HTTPS.
- Set request body limits to at least `MAX_AUDIO_BYTES`.
- Enable database backups.

## iOS Build

- Replace Release `VOICETYPE_BACKEND_URL` in `project.yml` with the production HTTPS host.
- Run `xcodegen generate`.
- Archived and uploaded `1.0.0 (9)` on 2026-06-16 through `xcodebuild
  -exportArchive` with App Store Connect upload destination. This build includes
  always-visible Add Credit purchase buttons, stronger keyboard app-open
  dispatch, no extra keyboard globe key, a system keyboard material background
  to remove the top and bottom color mismatch, stronger haptic/audio feedback, and
  immediate keyboard `Transcribing` state after tapping Stop. Build `9` also
  fixes TestFlight StoreKit receipt verification, purchase 401 messaging, keyboard
  button proportions, keyboard-mic ready-state recovery after Stop, and the
  switcher language subtitle. Apple accepted the package, App Store Connect
  reports build `9` as `VALID`, version `1.0` is linked to build `9`, and the
  Internal Testers group has access to all builds. Version `1.0` is submitted
  for App Review and configured for manual release after approval.
- Build `10` contains the stale keyboard-mic recorder recovery fix and was
  uploaded on 2026-06-16. App Store Connect reports build `10` as `VALID`.
  Validate it on device, then replace build `9` before public release.
- Build `11` adds the Live Activity / Dynamic Island keyboard microphone status
  surface and a stronger in-memory transcription state machine. It was uploaded
  on 2026-06-16 and is waiting for App Store Connect processing before TestFlight
  availability.
- Build `12` redesigns the Live Activity as a smaller Liquid Glass-style pill
  with a code-rendered VoiceType waveform mark, then uploads it for TestFlight
  processing on 2026-06-16.
- Build `13` improves that Live Activity pass with higher-contrast lock-screen
  text, a stronger readability scrim, a shorter Dynamic Island status chip, and a
  stable-width timer pill. It was uploaded for App Store Connect processing on
  2026-06-16.
- Build `14` fixes the lock-screen/Home Screen Live Activity foreground rendering
  by separating the Liquid Glass background from all text/logo/timer content and
  adding the background through `containerBackground(for: .widget)`. It was
  uploaded for App Store Connect processing on 2026-06-16.
- Build `15` fixes the session-length keyboard mic teardown: the length setting
  now caps only one Speak clip, idle keyboard-ready mode stays armed, picker
  changes re-check the real recorder before republishing ready state, and broken
  Stop commands recover ready instead of silently returning. It was uploaded for
  App Store Connect processing on 2026-06-16.
- Build `16` adds the Live Activity epoch/serialization fix from commit `f21cdab`
  so stale recording updates cannot reopen the activity after the mic ends, and
  switches compact Dynamic Island back to a short status dot instead of a running
  timer. It was uploaded for App Store Connect processing on 2026-06-16.
- Build `17` restores `Session length` to the intended keyboard mic lifetime
  measured from Turn on keyboard mic, adds a separate 10-minute Speak clip cap,
  removes elapsed timers from Live Activity/Dynamic Island, and aligns expanded
  Dynamic Island as logo left plus mic status right.
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
