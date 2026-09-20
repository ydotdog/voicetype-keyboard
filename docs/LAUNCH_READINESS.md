# Launch readiness — 2026-09-13

## Current candidate: build 24, 2026-09-14

An explicit tap on the inactive keyboard microphone opens VoiceType and automatically
starts a background session; the user returns to the host app manually. New sessions
use the saved duration, defaulting to 5 minutes, and duplicate activation preserves
the existing deadline. The complete suite passed 105 iOS and 6 packaging/shared-state
checks; Release archive/signatures/version checks passed. Version 24 was subsequently reinstalled and successfully launched on iPhone10
under the user's next request. The same archive was uploaded to TestFlight, processed
as VALID, and is IN_BETA_TESTING for Internal Testers. Test instructions were saved.
The newly invited developer user has not accepted the Apple account invitation and
is not yet eligible for group membership. Physical activation/dictation validation
remains with the user. **Not ready to launch; formal App Review remains paused.** See [DEVICE_FIX_24.zh-CN.md](DEVICE_FIX_24.zh-CN.md).

## Earlier candidate: build 23, 2026-09-14

Build 23 replaces visible Speak text with a microphone icon, reads actual levels at
20 Hz, enables recording haptics, and moves failed audio to independent History
jobs. History retries cannot publish to keyboard auto-insert or mutate live capture.
81 iOS checks, 6 packaging/shared-state checks, native screenshot review and signed
Release archive passed. Installed version 23 is verified on the iPhone; launch was
refused because the device is locked. Physical feel, full dictation/music behavior
and outstanding payment/long-session release checks remain pending. **Not ready to
launch; App Review remains paused.** See [DEVICE_FIX_23.zh-CN.md](DEVICE_FIX_23.zh-CN.md).


## Earlier device repair: build 22, 2026-09-14

Build 21 failed the user's real dictation flow (Starting followed by microphone-off)
and interrupted music. Build 22 restores a native SwiftUI Link to open the app,
enables audio mixing, and avoids pausing/restarting an already correctly bounded
five-minute recorder at Speak. It passed 68 iOS tests and 6 packaging/shared-state
checks, was archived/signed, and installed/launched on the iPhone. **Real-device
dictation, insertion, direct opening and music coexistence are awaiting confirmation.**
App Review remains paused. See [DEVICE_FIX_22.zh-CN.md](DEVICE_FIX_22.zh-CN.md).

## Earlier build 21 evidence

**Not ready to launch. App Review is paused.** Build 19's reported keyboard launch
crash has a code fix. After installing build 20, the user provided feedback on the
keyboard UI. Build 21 incorporates that feedback; the complete current-build
activation → keyboard dictation → text insertion flow still needs physical-device
evidence. An archive, health check or unit suite does not establish that flow.

The deployed and verified follow-up backend has SHA-256
`eecaf9d9a1999d085ced15ae37cc2e33e70e6023db1f26c0a25f709a7d7c6dca`.
Deployment completed on 2026-09-13 after private, verified backups. Public
readiness reports all 13 checks true. Build 20 was installed and launched on the
physical iPhone over USB on 2026-09-13 at 19:51 America/New_York. Device inventory
confirmed version 1.0.0 (20); keyboard/session interaction remains unverified.

Build 21 removes standalone recording and duplicate Home destinations, moves
balance to Credit, and simplifies/centers the keyboard. Actual recorder metering
now drives a smoothed waveform; silence, Stop, stale samples, access revocation
and disappearance clear it. The complete iOS suite passed 66 checks (48 application
Swift tests, 17 keyboard tests, 1 native capture XCTest); packaging and the executed
Swift bridge passed 6 checks. A later capture-only improvement passed all 17 keyboard
checks again. The final compact-layout revision (160 pt normal height, top-left logo,
waveform without a visible Stop title) also passed all 17 keyboard tests and native
width/theme captures: `/private/tmp/voicetype-ui21-compact-left.log`. Release archive `build/VoiceType-1.0.0-21-compact.xcarchive` passed strict
signing and version checks for the app and both extensions; it contains no test bundles. See
[UI_REVIEW_21.md](UI_REVIEW_21.md). Build 21 was installed over USB and launched on 2026-09-14 03:53 EDT. Device inventory
confirmed 1.0.0 (21); real dictation and waveform verification remain pending.
Evidence: `/private/tmp/voicetype-installed21-verified-20260914.json` and
`/private/tmp/voicetype-launched21-20260914.json`.

Status vocabulary is deliberately limited: **Passed** means the stated bounded
check has evidence; **Failed** means a reproduced/reported defect remains;
**Untested** means the necessary evidence is missing. A Passed row is not a claim
that the entire feature works on a real device or with real payment settlement.

## Verification matrix

| Scope | Status | Evidence / remaining boundary |
| --- | --- | --- |
| Earlier Python regression baseline | Passed | 66 checks rerun on 2026-09-13: 60 backend, 5 packaging, 1 executed Swift bridge; 11.21 seconds. External provider/Apple behavior is mocked. |
| Final Python regression and financial security checks | Passed | 115 checks: 109 backend, 5 packaging, 1 executed Swift bridge; 11.81 seconds. Includes 28 launch-security, 13 refund and 8 streamed-body checks. Local run on final backend hash `eecaf9d9a199`. One local LibreSSL/urllib3 compatibility warning; no failures. |
| Final Swift application and keyboard regression suites | Passed | 57 tests: 44 app tests in 7 suites, 13 keyboard tests in 1 suite. Final v7 run reported by the iOS owner; `/private/tmp/voicetype-readiness-v7.*`. Includes 401/missing-Keychain same-owner recovery, original audio and pre-export checkpoint preservation, and clip offsets. This supersedes the earlier 10-test baseline. |
| Existing PostgreSQL 16 baseline | Passed | Earlier source `4bc9c68ecdba` passed repeated migration, per-user locks/isolation, replay/current balance, concurrent one-debit and restart checks in `voicetype_release_qa_20260913`. |
| Final PostgreSQL migrations and transactions | Passed | Final candidate `eecaf9d9a199` passed on PostgreSQL 16 in isolated `voicetype_release_qa_20260913`: migration twice, user/ledger isolation, row locks, replay/current balance, concurrent one-debit, restart replay, model-default migration, welcome backfill/delete/recreate, refund/reversal ordering and deletion cascade. |
| Physical iPhone installation and app launch | Passed | USB connection and developer services were available. Installed the archived build and verified device inventory as 1.0.0 (20), then launched `com.kyleqi.voicetype`. Evidence: `/private/tmp/voicetype-installed20-verified.json` and `/private/tmp/voicetype-launched20.json`. Launch command success does not establish keyboard operation. |
| Current physical iPhone keyboard opens and can be selected | Untested | Build 19 failed; build 20 was installed and the user then provided keyboard-UI feedback. Build 21 requires current-device verification. Automated keyboard checks cannot prove extension availability on this device. |
| Keyboard microphone session, third-party text field and final insertion | Untested | Capture a successful current-device flow from activation through returned text insertion. Include full-access disabled and host apps that restrict custom keyboards. |
| Interruptions, lock/background, audio route changes and clip limit on iPhone | Untested | Unit/state tests do not exercise iOS audio-session scheduling, calls, Bluetooth changes or extension memory termination. |
| Saved recording retry, ownership, app relaunch and expired authentication on iPhone | Untested | Earlier state tests passed; verify actual retained audio, same UUID/duration, no cross-account access and exactly one customer debit. |
| Backend completed/concurrent retry accounting | Passed | Existing tests cover completed replay, current balance, independent users, failure/cancellation release and stale-worker ownership. Completed keys have no expiry. |
| Retry after server default model changes | Passed | New tests cover completed and pending claims, including migration from legacy fingerprints. Omitted model stays omitted in the semantic fingerprint; each claim retains its original selected model. An explicit model change still conflicts. |
| Five-minute dead-worker recovery and total provider deadline | Passed | New isolated behavioral tests replace the previous 30-minute claim wait with a 300-second processing lease and a 120-second total provider deadline. Actual process-kill/network-loss experiment remains untested. |
| Actual audio duration before provider spend | Passed | Local real WAV/AAC decode tests, invalid/playlist rejection, overlong clip, timeout/child termination and forged client duration reservation checks. Decoder supports at most 600 seconds and restricts formats/protocols; no provider call on validation failure. |
| Global audio work bound | Passed | Local busy-path test rejects before decode. On the 2-CPU / 1,976-MiB VM, final isolated image decoded two 600-second, 19.2-MB WAV uploads concurrently in 2.387 seconds; a third job returned 503 before decode. Container capped at 1 CPU / 512 MiB, peak 355,880,960 bytes (339.4 MiB), no OOM. This peak includes the in-process test client, buffers, tmpfs and child processes; it is not isolated ffmpeg RSS. |
| Authoritative provider duration and zero-token billing | Passed | Tests reproduce and fix ignored `usage.seconds` (600 seconds previously charged as 1) and valid zero tokens being replaced with estimated usage. One actual 6.6-second synthetic OpenAI mini-transcribe call in isolated QA returned the exact expected phrase, 66 input / 23 output tokens in 2.332 seconds. Replay made no second provider call and preserved exactly one 340-credit debit while returning current balance. This real-provider run used source `978d9d17c719`. |
| Request bodies bounded before parsing and disk spooling | Passed | Final source tests cover missing/false Content-Length, multipart fields, partial-file cleanup, valid chunked audio, auth JSON, StoreKit transaction and V2 webhook JSON. Reproduction previously consumed all 2 MiB before 413; the fix stops at the bounded receive boundary. Auth cap 32 KiB, transaction 96 KiB, webhook 192 KiB, audio limit plus 64 KiB multipart overhead; maximum valid 128-KiB signed webhook field is accepted. Existing Caddy has no active body cap, so application enforcement is required. |
| Final body-limit Linux image and PostgreSQL rerun | Passed | Tag `gcp-vm-backend:readiness20-uploadlimit`, source `eecaf9d9a199`, passed both isolated scripts. Missing-length audio stream returned 413 after 131,072 bytes of a 2,097,152-byte offered file; streamed auth/transaction/webhook JSON also stopped at their limits. Final media rerun used a mocked provider, real AAC/WAV decoding and the existing isolated QA database. |
| Welcome grant survives deletion/recreation | Passed | New tests cover same-identity denial after deletion, distinct identities, atomic rollback, concurrent grant attempts, legacy backfill and dedicated key stability across JWT rotation. |
| Welcome marker secret and revised privacy deployed | Passed | Dedicated stable key provisioned once and preserved in a mode-600 backup; no value was logged. Public readiness confirms the key and decoder, and the served privacy policy includes the keyed-hash retention disclosure. Preserve this key across releases/restores. |
| Local refund/reversal ledger lifecycle | Passed | Tests cover duplicate/concurrent notifications, original grant amount, negative balance, reversed and out-of-order events, refund before client purchase delivery, deletion cascade, wrong-account rejection and rollback after ledger failure. |
| Local signed-notification verification | Passed | Real ES256 verification with a locally generated trusted certificate chain verifies both outer notification and nested transaction; unsigned inner/outer payloads are rejected. Certificate OCSP network checks are mocked; certificates are not Apple-issued. |
| App Store server notification URL configuration | Passed | Both Sandbox and Production URLs point to `https://voicetype.y.dog/v1/billing/storekit/notifications`, with both versions V2. All four fields were read back through the official ASC API on 2026-09-13; the first immediate read was stale, and a subsequent read verified the saved values. No review or version submission was changed. |
| Live Apple refund notification delivery | Untested | Request an Apple TEST notification, then observe actual sandbox refund/reversal and ledger reconciliation. No suitable App Store Server API In-App Purchase key was found in the known project credential locations; the existing ASC API key is a separate credential type. URL configuration and invalid-signature rejection do not establish Apple delivery. |
| Real Apple sign-in, authorization-code exchange and revocation | Untested | Local tests verify failure/subject binding and account preservation; no successful live exchange/delete cycle in this follow-up audit. |
| Strict real StoreKit purchase, delivery retry and finish | Untested | Development JWS/unit tests cover logic and rejection. Exercise sandbox purchase for each pack, backend-response loss, relaunch and pending/cancelled/unverified outcomes. |
| Concurrent purchase/transcription balance display | Passed | iOS owner replaced mutation-response balance assignment with a guarded authoritative profile refresh and verified overlap/order regressions in the final Swift suite. Physical overlapping-purchase/transcription behavior remains untested. |
| Final build 20 release archive | Passed | `build/VoiceType-1.0.0-20.xcarchive` (durable copy of `/private/tmp/VoiceTypeBuild20-readiness-20260913.xcarchive`) succeeded. App, keyboard and Live Activity are all 1.0.0 (20); no XCTest bundles; deep strict codesign verification passed. Reported by iOS owner. Build 20 has not been uploaded to Apple. |
| Final backend deployment and readiness | Passed | Production source matches `eecaf9d9a199`; exact QA image `5cbc491c61c4` deployed after verified source/image/env/database backups. Internal/public readiness: all 13 checks true. Public health/privacy/support/product catalog return 200; invalid signed notification returns 401. PostgreSQL/Caddy were not recreated. |
| Actual deployment backup restoration | Passed | `scripts/verify_backup_restore20.py` restored the pinned `62f55569c3ba` backup in a temporary PostgreSQL 16 container with no network, 1 CPU, 384 MiB memory and 256 MiB tmpfs. Every table-data fingerprint and sequence state matched; constraints/indexes were valid. Temporary data/container were removed; all live container IDs/start times were unchanged. No row contents were logged or provider requests made. Evidence: `/private/tmp/voicetype-backup-restore20.log`. |
| Bounded production service logs | Passed | PostgreSQL, backend and Caddy had unlimited JSON logs. A subsequent Compose-only maintenance set each to 10 MiB per file, 3 files, and recreated all three services with the same images, private environment files, data mounts and ports. All 13 readiness checks passed afterward. The first postcheck falsely compared environment-list ordering; a corrected value comparison and independent runtime verification passed. Evidence: `/private/tmp/voicetype-log-bounds20-verified.log`. |
| Provider latency/error and Apple delivery failure monitoring | Untested | Existing request-error logs and readiness checks are not verified alert delivery or provider-latency monitoring. Complete operational detection checks together with the live Apple TEST/refund flow. |
| App Review video, first 3 IAPs and final submission | Untested | Intentionally paused. Notes/video have not been uploaded. First IAPs must accompany the app through the ASC UI after functional verification. |

## Financial and lifecycle closure requirements

The welcome-credit marker retains only a keyed hash and grant timestamp, with
no raw Apple identifier, email, name or VoiceType account ID. It survives account
deletion only to stop repeated claims while the welcome program operates. Both
the served policy and repository policy disclose this exception. Extant grants
are backfilled; grants belonging to accounts already deleted before this
migration cannot be reconstructed. Rotating or losing the dedicated key would
reset eligibility and must not be treated as routine JWT rotation.

The implemented refund policy reverses the original granted pack amount, even if
that makes credits negative after consumption. Further transcription requires
sufficient positive credit; this never bills a payment method automatically.
Apple refund reversals restore that adjustment. Notifications are signed,
deduplicated and ordered by Apple's signed date. A verified refund received
before purchase delivery is retained only if its app account token identifies
an existing account; it prevents a later stale receipt from granting refunded
credit. These state/event rows cascade on account deletion. Unknown/deleted
accounts never receive credit from notifications. Live webhook URLs are configured;
Apple TEST and sandbox delivery remain Untested despite passing local ledger tests.

Completed transcription retries prevent a second customer ledger debit. A
provider timeout or process death before a durable result can still leave an
uncertain upstream charge; a later explicit retry may incur another provider
charge. Local tests cannot prove the provider's settlement outcome. Reservations
use decoded duration and an estimated output budget, so the final actual token
cost can still exceed the estimate; the current ledger caps the customer charge
at spendable credit. Measure this loss with real clips before choosing a reserve
margin or changing user-visible pricing.

Schema changes are additive, but rolling back to the previously deployed
`4bc9c68ecdba` backend is not behaviorally equivalent. It does not enforce the new
welcome-marker/refund rules or understand version-2 request fingerprints. Older
releases before that baseline also lack durable transcription idempotency. Keep
the previous image, private environment and verified database dump for recovery,
but do not automatically restore a database over newer purchases, refunds or
transcriptions. Preserve the dedicated welcome key even during a rollback.

## Source contracts and evidence

- [OpenAI transcription request/response reference](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create): token usage and duration usage are separate variants; duration usage includes `seconds`.
- [OpenAI file transcription guide](https://developers.openai.com/api/docs/guides/speech-to-text): diarization clips longer than 30 seconds require a chunking strategy. The backend now supplies `auto`; Whisper requests duration-bearing verbose JSON.
- [Apple notification types](https://developer.apple.com/documentation/AppStoreServerNotifications/notificationType), [notification UUID](https://developer.apple.com/documentation/appstoreservernotifications/notificationuuid) and [signed date](https://developer.apple.com/documentation/appstoreservernotifications/signeddate): refund/reversal behavior, duplicate detection and latest-event ordering.
- [Apple server notification URL configuration](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/enter-server-urls-for-app-store-server-notifications), [TEST notification request](https://developer.apple.com/documentation/appstoreserverapi/request-a-test-notification) and [In-App Purchase API keys](https://developer.apple.com/documentation/appstoreserverapi/creating-api-keys-to-authorize-api-requests): configuring the URLs is separate from proving delivery, and the Server API uses its own key type. Saved configuration evidence: `/private/tmp/voicetype-notification-urls20-observed.json`.
- Local reproducible checks: `backend/tests/test_launch_security.py`, `backend/tests/test_refunds.py`, `backend/tests/test_upload_streaming.py`, existing `backend/tests/test_billing.py` and `backend/tests/test_reliability.py`; isolated scripts: `scripts/verify_postgres_release.py` and `scripts/verify_backend_media_release.py`.
- Final-image server evidence: `/private/tmp/voicetype-readiness20-uploadlimit-build.log`, `voicetype-readiness20-uploadlimit-postgres.log` and `voicetype-readiness20-uploadlimit-media.log`; remote logs use `/tmp/` with the same names.
- Final candidate directory: `/opt/voicetype/releases/20260913-readiness20-uploadlimit`; image ID `sha256:5cbc491c61c448e570c4f28af38c1700a0021ce808c183fa5197f4cd1c939155`, Linux amd64, 241,033,091 bytes. Source archive SHA-256 `96d46bb7e7b3827ecb6bf18dad73efeef46fff6dbf2185211d94533a5533b254`. During isolated QA, before the subsequent production deployment, the live backend remained `4bc9c68ecdba` and its container/image/start time were unchanged.
- Prior-image server evidence: `/private/tmp/voicetype-readiness20-build.log`, `voicetype-readiness20-postgres.log` and `voicetype-readiness20-media.log`. Synthetic audio SHA-256: `13666d782e87bd152bab875013c8817ccc891336de94633470518fb25d4261a1`. Audio was generated from a benign English release-test phrase; no personal recording was sent.

The final backend was deployed after QA; the prior source/image/private environment
and database remain in `/opt/voicetype/backups/build20-20260913T222748Z-bf4a08a2b883`.
The verified database dump SHA-256 is
`62f55569c3ba27da2f2142b486d5a99104883bb6395c1a54d1ec6f4b99a4dc7e`.
Deployment evidence: `/private/tmp/voicetype-deploy20.log`.
Application/financial QA used synthetic accounts and virtual credit in an isolated
database, with process-only fake Apple authentication. Separately, the actual
production backup was restored and compared inside a network-isolated temporary
database; no restored account was used through an API, and no row data was logged.
One synthetic provider request used the existing server-side provider credential;
no private user audio or real purchased credit was involved.
Build 20 has not been uploaded or submitted to App Review.
