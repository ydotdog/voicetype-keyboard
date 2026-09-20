# Release checklist

## Current iOS candidate 24

- [x] Native keyboard Link automatically enables the microphone after opening VoiceType; user returns manually.
- [x] Default 5 minutes or latest saved duration; duplicate activation preserves the current window.
- [x] Integration coverage for foreground/sign-in/permission and fresh activation after expiry; ordinary links cannot start capture.
- [x] 105 iOS checks, 6 packaging/shared-state checks, Release archive and strict signatures passed.
- [x] Version 24 installed and confirmed by iPhone inventory.
- [x] Reinstall and launch version 24; upload the same archive to TestFlight, verify VALID / IN_BETA_TESTING for Internal Testers, and save test instructions.
- [ ] Newly invited developer user accepts the Apple account invitation, then joins Internal Testers.
- [ ] User verifies keyboard → automatic activation → manual return → dictation and insertion.
- [ ] Complete remaining physical audio/session and real payment checks before submission.

See [DEVICE_FIX_24.zh-CN.md](DEVICE_FIX_24.zh-CN.md). App Review remains paused.

## Earlier iOS candidate 23

- [x] Icon-only keyboard microphone and actual, responsive sound levels.
- [x] Recording-session haptics enabled; one prepared feedback event per press.
- [x] Independent, owner-bound failed recordings in History; no new-capture gating.
- [x] Regression coverage for actual keyboard upload failure followed by another clip, concurrent History retry, late callbacks, migration and storage failure.
- [x] 81 iOS checks and 6 packaging/shared-state checks; 43 native screenshots captured and representative states reviewed.
- [x] Archive/signatures/version 23 verified; installed device inventory confirmed.
- [ ] Unlock device and verify real sound, vibration, music coexistence and complete dictation.
- [ ] Complete remaining real account/payment and long-session checks below before any App Review submission.

See [DEVICE_FIX_23.zh-CN.md](DEVICE_FIX_23.zh-CN.md). Earlier candidate results below are historical.


App Review is paused. Use [LAUNCH_READINESS.md](LAUNCH_READINESS.md) as the current
Passed / Failed / Untested evidence matrix. The reported physical-iPhone keyboard
failure remains blocking. Earlier build history is in
[DEPLOYMENT_STATUS.md](DEPLOYMENT_STATUS.md) and [RELEASE_2026-09-13.md](RELEASE_2026-09-13.md);
historical uploads and tests do not establish current launch readiness.

## Earlier iOS candidate 21

Superseded by installed build 22 after the user's Starting/session-close and music-interruption reports. Current fixes and unresolved physical checks are in [DEVICE_FIX_22.zh-CN.md](DEVICE_FIX_22.zh-CN.md). Build 22 passed 68 iOS tests and 6 packaging/shared-state checks; real dictation remains unconfirmed.

- [x] Remove standalone recording and duplicate Home entries; center and simplify keyboard controls.
- [x] Replace fixed bars with measured microphone-level animation and silence/stale/access/Stop resets.
- [x] Pass 66 iOS checks and 6 packaging/shared-state checks; the final compact layout and capture changes also passed all 17 keyboard tests.
- [x] Archive and verify signatures/version 1.0.0 (21) for the app and both extensions: `build/VoiceType-1.0.0-21-compact.xcarchive`.
- [x] Install and launch build 21 over USB (2026-09-14 03:53 EDT); verify device inventory as 1.0.0 (21).
- [ ] Validate real sound feedback and the complete third-party dictation flow on build 21.

## Backend and earlier candidate 20 evidence

- [x] Freeze final backend `eecaf9d9a199` and app 1.0.0 (20); full pins are in the readiness matrix.
- [x] Final automated suites: 115 Python-driven checks (109 backend + 5 packaging +
  1 executed Swift bridge), and 57 Swift application/keyboard tests passed.
- [x] Build the new ffmpeg image and verify real AAC/WAV decode, invalid media,
  two near-limit concurrent uploads, third-job rejection and streamed body limits
  on the target Linux VM at 1 CPU / 512 MiB. Local tests cover overlong rejection
  and decoder cancellation/timeout. Final tag: `gcp-vm-backend:readiness20-uploadlimit`.
- [x] Run `scripts/verify_postgres_release.py` against an isolated PostgreSQL 16
  database whose name begins `voicetype_release_qa_`. Verify additive migrations,
  grant markers, refund ordering, per-user locks and durable idempotency.

## Physical iPhone verification

- [x] Install and verify version 1.0.0 (20) on the physical iPhone; app launch
  command succeeded on 2026-09-13 at 19:51 America/New_York.
- [ ] Fix and reproduce successful keyboard availability, selection, microphone
  activation and final text insertion in a third-party app.
- [ ] Verify permission denial/recovery, Full Access disabled, secure text fields,
  and host apps that do not allow custom keyboards; show actionable guidance.
- [ ] Verify the selected Session length controls microphone-session lifetime
  from activation. Check the independent 10-minute clip cap and Forever behavior.
- [ ] Verify lock/background transitions, interruptions, Bluetooth/audio changes,
  rapid start/stop, end-session during transcription and extension/app relaunch.
- [ ] Verify retained recording retry across connection loss and expired login:
  same audio/duration/request UUID, same-owner recovery, no duplicate debit,
  explicit discard, explicit sign-out and account-switch cleanup.
- [ ] Verify real Apple sign-in and account deletion/revocation. Signing in again
  must not reclaim welcome credit; the deleted session must be rejected.
- [ ] Verify all three sandbox credit packs, cancellation/pending/unverified
  purchases, delivery retry, app relaunch and concurrent balance refresh.
- [ ] Verify refund/reversal and negative-credit messaging without any automatic
  monetary charge. Match the observed balance to the server ledger.

## Production configuration and rollout

- [x] Preserve and checksum the Postgres dump, private configuration, source and
  prior image; record the rollback
  boundary. The previous `4bc9c68ecdba` image lacks version-2 request-fingerprint,
  refund and grant-marker enforcement; older releases also lack durable
  idempotency. Additive schema compatibility does not make these safe automatic
  behavioral rollbacks. Never overwrite newer ledger writes with an old dump.
- [x] Provide a dedicated stable random `SIGNUP_GRANT_HMAC_SECRET`. Preserve it
  across JWT rotations, releases and restores; do not use the QA key. Welcome
  grants fail closed without it in production.
- [x] Keep `STOREKIT_VERIFICATION_MODE=strict`,
  `ALLOW_UNVERIFIED_STOREKIT_JWS=false`, `REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN=true`,
  `APPLE_AUTH_DEV_BYPASS=false` and `ALLOW_DEV_CREDIT=false`.
- [x] Keep `STOREKIT_ACCEPTED_ENVIRONMENTS=SANDBOX,PRODUCTION` while this service
  supports TestFlight/App Review and public purchases. Do not disable Sandbox
  merely because the public app has launched.
- [x] Confirm backend-only provider credentials, Apple identity/revocation
  credentials, app ID and trusted Apple root certificates; deploy the matching
  privacy and support text.
- [x] Verify `MAX_CONCURRENT_TRANSCRIPTIONS=2`, one worker and
  `TRANSCRIPTION_PROCESSING_LEASE_SECONDS=300` on the live container. The lease
  covers the 120-second provider deadline with recovery slack.
- [x] Configure App Store Server Notifications **V2**, for Sandbox and Production,
  to `https://voicetype.y.dog/v1/billing/storekit/notifications`. All four URL/version
  fields were read back and verified through the official ASC API on 2026-09-13.
- [ ] Request an Apple TEST notification and verify delivery; then test an actual
  sandbox refund and reversal. A suitable App Store Server API In-App Purchase
  key is not currently available in the known project credential locations.
  The existing App Store Connect key is a different credential type.
- [x] Verify final source/image hash, all 13 readiness checks, HTTPS pages and
  rejection of an invalid signed notification. Upload limits passed on the exact
  deployed image in isolated QA.
- [x] Restore the actual pinned deployment backup in an ephemeral, network-isolated
  PostgreSQL 16 container. All table-data fingerprints and sequence states match;
  restored constraints/indexes are valid. Temporary data removed, live containers
  unchanged. Evidence: `/private/tmp/voicetype-backup-restore20.log`.
- [x] Bound each service's Docker logs to 10 MiB per file and 3 files. All three
  services were recreated with unchanged images, private environment files, data
  mounts and ports; post-maintenance readiness passed all 13 checks.
- [ ] Verify provider latency/error and refund-delivery failure monitoring.
  Readiness does not prove payment settlement.

## App Review — resume only after functional sign-off

- [x] Create the final build 20 archive with all verified fixes; strict signing
  verification passed. Durable archive: `build/VoiceType-1.0.0-20.xcarchive`.
- [ ] After functional sign-off, upload the final archive, confirm processing and
  link that build to the app version. Build 20 has not been uploaded.
- [ ] Refresh actual version/build/IAP states in ASC; do not infer them from old
  screenshots or historical localization states.
- [ ] Include Small, Medium and Large consumable IAPs with the app in the same
  first-submission draft through the ASC UI. The old unresolved app-only
  submission cannot simply accept new items.
- [ ] Upload the revised review notes and a working physical-device demonstration
  made only with the user's iPhone-native recording. Neither has been uploaded.
- [ ] Review the concrete final submission, then submit. Keep manual release.
