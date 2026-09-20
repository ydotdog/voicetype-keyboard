# Deployment Status

## Current TestFlight — build 25, 2026-09-20

Version **1.0.0 (25)** is processed as **VALID**, **IN_BETA_TESTING**, and is
available in **Internal Testers**. English and Simplified Chinese testing notes
were saved and read back. Build ID: `9bc5476f-820e-4bcb-a868-e77c3c6a44cf`.
The formal App Store version remains `REJECTED` / `MANUAL`; no review submission
was created.

The build adds Live Activity dismissal microphone shutdown and an explicit stop
action, language/script preferences, Chinese punctuation normalization, and
account-scoped vocabulary with reviewed History correction learning. iOS system
collapse gestures do not report dismissal. Rare homophone name recognition still
varies despite hints; physical gesture/audio/keyboard testing remains pending.
See [DICTATION_25.zh-CN.md](DICTATION_25.zh-CN.md).

Validation: **113 distinct iOS tests** (112 full-suite + one new stop-intent test
in a passing 10-test activation run), **134 local backend/shared checks**, and
**128 backend tests in the Linux image**. Narrow/light/dark screens were rendered
and inspected. The signed Release archive is
`build/VoiceType-1.0.0-25-final.xcarchive`; all three bundles are `1.0.0 (25)`.
Evidence and TestFlight readback are in `build/release25/`.

The backend was deployed with all 13 readiness checks true. PostgreSQL, Caddy,
and every other running container retained its container ID. No database schema
or account data migration was required. Rollback source and image identifiers
are recorded under `/opt/voicetype/backups/dictation25-20260920T202214Z`; the previous
image is retained as `voicetype-backend:before-dictation25`.

- Running image: `sha256:be5c4e290a559b0adc2af0aede2bfbf8548f656353d0831cc52b2ff680fbf8f6`.
- `main.py`: `9e7a6b327227affdc5d3da752c2be8358a2e4aebe1bf136059cfe672cb97149d`.
- `dictation.py`: `72766c6e52832fe57b6d6ce5bbe55f02792ceb5bb89c4f787a3dfd91ee9ce552`.
- GitHub: baseline preserved in PR #1; feature development/self-review merged in PR #2.


## Earlier iOS installation — build 24, 2026-09-14

Version 1.0.0 (24) is installed on iPhone10 and verified by device inventory. It
adds keyboard-origin automatic microphone activation with the saved session length.
105 iOS tests, 6 packaging/shared-state checks and strict Release archive/signatures
passed. It was subsequently reinstalled and successfully launched on the user's
request. The same archive was uploaded at 05:32 EDT, processed as VALID, and is now
IN_BETA_TESTING for Internal Testers. Test instructions were saved. The newly invited
developer user must first accept the Apple account invitation before being added to
the group. Physical verification remains with the user. Backend unchanged; no formal
App Store submission was made. See [DEVICE_FIX_24.zh-CN.md](DEVICE_FIX_24.zh-CN.md).

## Earlier iOS installation — build 23, 2026-09-14

Build 23 is installed on iPhone10 and confirmed by the device inventory. Launch is
pending unlock. Archive/signatures and 81 iOS plus 6 packaging/shared-state checks
passed; physical verification remains pending. Backend deployment is unchanged.
No Apple upload or submission. See [DEVICE_FIX_23.zh-CN.md](DEVICE_FIX_23.zh-CN.md).


Last updated: 2026-09-13

## Earlier device repair — build 22

Build 22 is installed and launched on iPhone10 after the user's build 21 dictation/music failures. It restores direct app opening via native SwiftUI Link, adds audio mixing, and avoids unnecessary background recorder rearming. 68 iOS tests, 6 packaging/shared-state checks and archive signatures passed. Physical end-to-end results remain pending. Archive: `build/VoiceType-1.0.0-22.xcarchive`. No Apple upload or submission. See [DEVICE_FIX_22.zh-CN.md](DEVICE_FIX_22.zh-CN.md).

## Earlier verified status — 2026-09-13

- App Review remains paused. Current candidate **1.0.0 (21)** adds Home/keyboard simplification and measured microphone waveform feedback. The full suite passed 66 iOS checks and 6 packaging/shared-state checks; the subsequent compact layout (160 pt, logo top-left, waveform without visible Stop title) passed all 17 keyboard checks and final Release archive/signature/version checks. Archive: `build/VoiceType-1.0.0-21-compact.xcarchive`. Build 21 was installed over USB and launched on 2026-09-14 03:53 EDT; device inventory confirmed 1.0.0 (21). Physical sound/dictation verification remains pending. No build 21 upload or submission has occurred. See [UI_REVIEW_21.md](UI_REVIEW_21.md).
- Earlier candidate **1.0.0 (20)** passed **57 Swift
  tests** (44 application + 13 keyboard), Release archive creation, and strict
  code-signature verification. The archive is
  `/private/tmp/VoiceTypeBuild20-readiness-20260913.xcarchive`.
- Physical installation succeeded over USB on 2026-09-13 at 19:51 America/New_York.
  Device inventory confirmed version 1.0.0 (20), and the app launch command
  succeeded. Notes/keyboard/session validation remains pending. Build 20 has not
  been uploaded to Apple.
- Production backend `/app/main.py` now matches SHA-256
  `eecaf9d9a1999d085ced15ae37cc2e33e70e6023db1f26c0a25f709a7d7c6dca`.
  Final image `sha256:5cbc491c61c448e570c4f28af38c1700a0021ce808c183fa5197f4cd1c939155`
  passed isolated PostgreSQL/media/streaming checks and was deployed without
  recreating PostgreSQL or Caddy. Public readiness reports all **13 checks true**.
- Subsequent log-rotation maintenance recreated all three services with the same
  images, private environment files, data mounts and ports. Each now retains at
  most 3 × 10 MiB JSON log files. Public readiness again passed all 13 checks.
  Evidence: `/private/tmp/voicetype-log-bounds20-verified.log`.
- Private verified backups of the previous image/source/environment/database are
  under `/opt/voicetype/backups/build20-20260913T222748Z-bf4a08a2b883`. The dedicated
  welcome-credit identity key was provisioned once and backed up with mode 600.
  Preserve it across deployments and recovery. See
  [LAUNCH_READINESS.md](LAUNCH_READINESS.md) for evidence and rollback limitations.
- The actual pinned deployment dump was successfully restored and fully compared
  in a temporary network-isolated PostgreSQL 16 container. Temporary data were
  removed; the restoration drill itself did not restart live services.
- App Store Connect now has the V2 server notification URL set and read back for
  both Production and Sandbox. Apple TEST delivery and actual refund/reversal
  settlement remain unverified; App Review remains paused.
- Build 19 was uploaded on 2026-09-13 at 16:45 America/New_York, but was not linked
  or submitted for review. It predates the physical-keyboard crash fix and must
  not be submitted. Its [historical evidence](RELEASE_2026-09-13.md) is retained.

## Historical record — 2026-06-16

The entries below retain the earlier deployment/build history. Their build
numbers, App Review states, and outstanding tasks are not the current release
status; use the dated section above.

## GCP

- Account used by local `gcloud` configuration `voicetype-kq`: `kq@apeonwheels.com`.
- Project: `voicetype-y-dog-20260604`.
- Region/zone: `us-central1` / `us-central1-a`.
- VM: `voicetype-api`.
- Static IP: `34.10.43.168`.
- Firewall: public TCP 80/443 to VM tag `voicetype-api`.
- Backup: daily persistent disk snapshot policy `voicetype-daily-snapshot`, retained for 14 days.

## Runtime

The VM runs Docker Compose from `/opt/voicetype/app/deploy/gcp-vm/docker-compose.yml`.

Services:

- `backend`: FastAPI API on internal port `8080`.
- `postgres`: local Postgres 16.
- `caddy`: public reverse proxy on ports `80` and `443`.

Billing configuration:

- Credit packs: `$0.99`, `$4.99`, `$19.99` consumable StoreKit products.
- Granted credit units: `990,000`, `4,990,000`, `19,990,000`.
- `COST_MARKUP_BPS=7143`, covering standard 30% App Store commission plus 20% target profit.
- `ALLOW_DEV_CREDIT=false` in production.

Current public smoke tests:

```bash
curl http://34.10.43.168/health
curl https://voicetype.y.dog/health
curl https://voicetype.y.dog/health/ready
curl -I https://voicetype.y.dog/privacy
curl -I https://voicetype.y.dog/support
curl https://voicetype.y.dog/v1/billing/products
```

Expected response:

```json
{"ok":true,"service":"voicetype-api","model":"gpt-4o-mini-transcribe","database":"postgres","storekit_verification_mode":"strict"}
```

`/health/ready` returns HTTP 200 only when all production and App Store release
checks are true:

- JWT secret configured.
- OpenAI API key configured.
- Postgres reachable.
- StoreKit strict verification enabled.
- `appAccountToken` required.
- Apple App ID and root certificate material configured.
- Sign in with Apple token revoke credentials configured.
- Dev credit disabled.

Latest deployment sync:

- Date: 2026-06-13.
- Source: local `main` worktree after App Store readiness fixes.
- Updated VM paths: `/opt/voicetype/app/backend`, `/opt/voicetype/app/deploy/gcp-vm`.
- Rebuilt backend image and restarted `backend` and `caddy`.
- Verified `backend/main.py`, `deploy/gcp-vm/docker-compose.yml`, and
  `deploy/gcp-vm/Caddyfile.https` SHA-256 hashes match local files.
- Created a Sign in with Apple server-to-server key and deployed the revoke
  credentials to the VM.
- Verified `https://voicetype.y.dog/health/ready` returns HTTP 200 with
  `apple_signin_revoke_credentials=true`.
- Verified `https://voicetype.y.dog/privacy` returns HTTP 200 for GET and HEAD.
- Verified `https://voicetype.y.dog/support` returns HTTP 200 for GET and HEAD.
- Verified `https://voicetype.y.dog/v1/billing/products` returns the three
  consumable credit products.

Latest real transcription smoke test:

- Date: 2026-06-05.
- Model: `gpt-4o-mini-transcribe`.
- Result: HTTP 200, transcript returned, ledger debited, temporary smoke user deleted.

## App Store Build

Latest upload:

- Date: 2026-06-16.
- Version/build: `1.0.0 (12)`.
- Archive path: `/tmp/VoiceTypeBuild12GlassLiveActivity-202606161356.xcarchive`.
- Signing: automatic signing with team `WC3PWB5R2J`; export used
  `method=app-store-connect` and `destination=upload`.
- Upload method: `xcodebuild -exportArchive` with `method=app-store-connect`,
  `destination=upload`, and automatic signing.
- Result: Xcode reported `Uploaded VoiceType` and `Upload succeeded`; App Store
  Connect package processing started.
- App Store Connect version `1.0` is linked to build `9`. The Internal Testers
  TestFlight group has access to all builds, so build `9` is available to the
  internal group after App Store Connect processing.
- App Store Connect version `1.0` is submitted for App Review with build `9`.
  After the keyboard-mic stale recorder bug was reproduced in TestFlight, release
  was changed back to manual (`releaseType=MANUAL`) so build `9` cannot
  automatically go live if approved.
- Internal tester `qijialuabc@gmail.com` is in the Internal Testers group with
  state `INSTALLED`.
- StoreKit receipt verification is now environment-agnostic. `verify_storekit_payload`
  verifies against the transaction's own `environment` first, then the configured
  `APPLE_STOREKIT_ENVIRONMENT`, then Sandbox and Production. This accepts TestFlight
  Sandbox transactions without pinning the verifier to one environment, fixing
  the prior HTTP 401 that blocked TestFlight purchases and credit grants.
- Credit grants are still gated by `STOREKIT_ACCEPTED_ENVIRONMENTS`. For App
  Review and the next public release candidate, the VM currently uses
  `STOREKIT_ACCEPTED_ENVIRONMENTS=SANDBOX,PRODUCTION` so App Review sandbox
  purchases and public production purchases both grant credit. The old advice
  to remove Sandbox after launch is superseded: keep both environments while
  supporting TestFlight and App Review. The
  backend was redeployed from this code on 2026-06-16; already-paid stuck
  transactions grant retroactively via the client's unfinished-transaction
  replay (reopen the app or tap Restore purchases).
- Keyboard extension `CFBundleDisplayName` changed from `VoiceType Keyboard` to
  `VoiceType`, and `PrimaryLanguage` changed from `en-US` to `mul` (the ISO 639
  code for "multiple languages"), so the globe/keyboard switcher reads just
  `VoiceType` with no "English" subtitle underneath. The keyboard stays
  ASCII-capable (`IsASCIICapable: true`).
- Keyboard layout proportions tightened: unified side margins, equal-height
  return/delete keys with matching corner radii, and a rebalanced Speak pill.
- Client no longer mislabels a StoreKit submission HTTP 401 as "session expired";
  it now tells the buyer the purchase will credit automatically.
- Fixed a keyboard-mic regression where tapping Stop after a clip could collapse
  the session to "Open VoiceType" instead of returning to ready (the user then had
  to relaunch the app before voice-to-text worked again). The clip
  stop/restart/transcribe window now runs under a `beginBackgroundTask` so iOS does
  not suspend the app while the continuous recorder is momentarily stopped, and the
  recorder restart reasserts the audio session and retries once before giving up.
- Build `10` was archived at `/tmp/VoiceType-build10-20260616123206.xcarchive`
  and uploaded with `xcodebuild -exportArchive` on 2026-06-16. Xcode reported
  `Uploaded VoiceType` and `Upload succeeded`; App Store Connect reports build
  `10` (`e6befbc1-1459-4f8c-9edc-45c2ca48433a`) as `VALID`.
- Build `11` was archived at `/tmp/VoiceTypeBuild11LiveActivity.xcarchive` and
  uploaded with `xcodebuild -exportArchive` on 2026-06-16. The first export
  attempt failed because the new `com.kyleqi.voicetype.liveactivity` extension
  needed an App Store provisioning profile; retrying with
  `-allowProvisioningUpdates` created/downloaded signing assets and uploaded
  successfully.
- Current source is bumped to build `18` for the keyboard Stop handoff fix. A
  failed restart of the continuous keyboard recorder can no longer abort the
  current clip before export/transcription; the app keeps the bridge in
  `Transcribing`, continues processing the captured audio, retries ready-recorder
  recovery, and preserves keyboard auto-insert after a successful transcript.
- Build `11` also adds a Live Activity / Dynamic Island surface for the active
  keyboard microphone session, using the VoiceType app logo in compact and
  minimal presentations.
- Build `12` replaces the first Live Activity presentation with a smaller
  Liquid Glass-style pill, a code-rendered VoiceType waveform mark so the compact
  logo cannot render blank, and tighter Dynamic Island sizing.
- Build `13` improves the Live Activity readability pass: lock-screen text now
  sits on a stronger contrast scrim while keeping the Liquid Glass treatment, and
  the expanded Dynamic Island uses a compact status chip plus stable-width timer
  pill instead of loose status text next to changing seconds. It was archived at
  `/private/tmp/VoiceTypeBuild13ReadableLiveActivity-202606161412.xcarchive` and
  uploaded with `xcodebuild -exportArchive` on 2026-06-16; Xcode reported
  `Uploaded VoiceType` and `Upload succeeded`.
- Build `14` fixes the lock-screen/Home Screen Live Activity rendering bug where
  the Liquid Glass card could show wallpaper but no text. The foreground content
  is now drawn in a separate `ZStack` layer above a dedicated
  `VoiceTypeActivityGlassPanel`, and the widget background is supplied through
  `containerBackground(for: .widget)` so `glassEffect` is never applied to a
  view that contains `Text`. It was archived at
  `/private/tmp/VoiceTypeBuild14LiveActivityForegroundText-202606161714.xcarchive`
  and uploaded with `xcodebuild -exportArchive` on 2026-06-16; Xcode reported
  `Uploaded VoiceType` and `Upload succeeded`.
- Build `15` fixes the root session-length bug behind the keyboard mic dropping
  back to `Open VoiceType`: the limit now caps only a single dictation clip and
  never tears down an idle armed keyboard mic. Changing session length also
  re-verifies the live recorder before publishing ready state, and a Stop command
  with broken clip state repairs the armed mic instead of silently returning. It
  was archived at
  `/private/tmp/VoiceTypeBuild15SessionLengthKeyboardMic-202606161803.xcarchive`
  and uploaded with `xcodebuild -exportArchive` on 2026-06-16; Xcode reported
  `Uploaded VoiceType` and `Upload succeeded`.
- Build `16` includes the Live Activity sync race fix from commit `f21cdab`:
  update/end operations now carry a monotonic epoch through a serialized
  ActivityKit controller path so stale recording updates cannot resurrect the
  Live Activity after the mic is off. It also keeps the compact Dynamic Island
  short by showing a status dot instead of a running timer, while preserving the
  one-row expanded island layout. It was archived at
  `/private/tmp/VoiceTypeBuild16LiveActivitySyncRace-202606161950.xcarchive` and
  uploaded with `xcodebuild -exportArchive` on 2026-06-16; Xcode reported
  `Uploaded VoiceType` and `Upload succeeded`.
- Build `17` restores `Session length` to the intended keyboard-mic session
  lifetime: 5 minutes, 12 hours, or Forever are measured from Turn on keyboard
  mic, not from Speak and not from changing the picker. A current Speak clip is
  stopped and transcribed before the expired session closes, while each Speak
  clip has its own 10-minute safety cap. The Live Activity and Dynamic Island
  no longer display elapsed duration; expanded Dynamic Island shows the logo on
  the left and the current mic status on the right. It was archived at
  `/private/tmp/VoiceTypeBuild17SessionLengthLiveActivity-202606162103.xcarchive`
  and uploaded with `xcodebuild -exportArchive` on 2026-06-16; Xcode reported
  `Uploaded VoiceType` and `Upload succeeded`.
- Build `18` fixes the Stop path that could still drop the keyboard back to
  `Open VoiceType` and lose the current clip when the replacement continuous
  recorder failed to start during the stop -> restart -> transcribe handoff.
  The source clip URL is now detached before ready-recorder recovery can run,
  recorder recovery failure during `.transcribing` keeps publishing bridge
  heartbeats instead of tearing down the session, and transcription proceeds even
  if ready recovery is temporarily unavailable. It was archived at
  `/private/tmp/VoiceTypeBuild18StopHandoff-202606162141.xcarchive` and uploaded
  with `xcodebuild -exportArchive` on 2026-06-16; Xcode reported
  `Uploaded VoiceType` and `Upload succeeded`.

App Store Connect configuration completed:

- Consumable IAP products exist and are `WAITING_FOR_REVIEW`:
  - `com.kyleqi.voicetype.credits.small`: reference name `990,000 Credits`, USD 0.99.
  - `com.kyleqi.voicetype.credits.medium`: reference name `4,990,000 Credits`, USD 4.99.
  - `com.kyleqi.voicetype.credits.large`: reference name `19,990,000 Credits`, USD 19.99.
- Each consumable has availability enabled for all territories, a permanent
  manual price schedule in App Store Connect, and a complete App Review
  screenshot asset.
- The three consumable IAP products are selected in App Store Connect version
  `1.0` under `In-App Purchases and Subscriptions`.
- English metadata, privacy policy URL, support URL, and marketing URL are set.
- Age rating declaration is set.
- Primary category is set to Productivity.
- iPhone 6.7-inch and iPad Pro 12.9-inch screenshots uploaded and processed.
- App Review contact details and review notes are set.
- App Privacy is published. The nutrition label lists Name, Email Address,
  Audio Data, Other User Content, User ID, and Purchase History as linked to the
  user, used for App Functionality, and not used for tracking.
- Paid Apps Agreement, bank account, U.S. W-9 tax form, and Digital Services Act
  compliance are `Active` in App Store Connect Business as of 2026-06-15.
- App Store version `1.0` was submitted for review on 2026-06-16 at
  03:14:24 UTC. Review submission `83e859ed-1370-4256-aabb-73b6bc60b1f2`
  is `WAITING_FOR_REVIEW`, version `1.0` is `WAITING_FOR_REVIEW`, the three IAP
  products are `WAITING_FOR_REVIEW`, and release is manual after approval.

## DNS

Target production hostname: `voicetype.y.dog`.

`y.dog` is delegated to Cloudflare nameservers:

- `nena.ns.cloudflare.com`
- `jarred.ns.cloudflare.com`

The production record is configured in Cloudflare:

- Type: `A`
- Name: `voicetype`
- Value: `34.10.43.168`
- Proxy: DNS only.

Authoritative verification:

```bash
dig @nena.ns.cloudflare.com voicetype.y.dog A +short
dig @jarred.ns.cloudflare.com voicetype.y.dog A +short
```

Both should return:

```bash
34.10.43.168
```

## TLS

Caddy is active with automatic HTTPS for `voicetype.y.dog`.

HTTP redirects to HTTPS:

```bash
curl -I http://voicetype.y.dog/health
```

Expected first line:

```text
HTTP/1.1 308 Permanent Redirect
```

## Secrets

`OPENAI_API_KEY` is configured on the VM in `/opt/voicetype/env/backend.env`.
`APPLE_APP_APPLE_ID`, Apple root certificate material, strict StoreKit flags, and
`ALLOW_DEV_CREDIT=false` are confirmed by `/health/ready`.

Sign in with Apple revoke credentials are configured on the VM and confirmed by
`/health/ready`.

To rotate it later:

```bash
gcloud compute ssh voicetype-api --zone us-central1-a --project voicetype-y-dog-20260604 --command '
sudo sed -i "s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=YOUR_KEY_HERE/" /opt/voicetype/env/backend.env
cd /opt/voicetype/app
sudo docker compose -f deploy/gcp-vm/docker-compose.yml up -d --no-deps --force-recreate backend
'
```

Still required for App Store release:

- Monitor App Review and respond to any reviewer messages or rejections.
- Validate build `12` keyboard-mic stale-recorder recovery on device and replace
  build `9` before public release.
- Superseded environment advice: retain `SANDBOX,PRODUCTION` while supporting
  TestFlight and App Review, including after public launch. Recreate the backend
  to load an environment-file change; a container restart does not reload it.
