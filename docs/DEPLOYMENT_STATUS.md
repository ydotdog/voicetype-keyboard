# Deployment Status

Last updated: 2026-06-16

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
  purchases and public production purchases both grant credit. After the public
  launch is stable, tighten it to `PRODUCTION` and restart the backend. The
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
- Current source is bumped to build `17` for the corrected session-length
  semantics and Live Activity layout cleanup. `Session length` again limits the
  armed keyboard mic session from the moment the user taps Turn on keyboard mic;
  a separate 10-minute cap protects each Speak clip. Live Activity and Dynamic
  Island no longer show an elapsed timer.
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
sudo docker compose -f deploy/gcp-vm/docker-compose.yml restart backend
'
```

Still required for App Store release:

- Monitor App Review and respond to any reviewer messages or rejections.
- Validate build `12` keyboard-mic stale-recorder recovery on device and replace
  build `9` before public release.
- After public launch is stable, set `STOREKIT_ACCEPTED_ENVIRONMENTS=PRODUCTION`
  on the VM and restart the backend.
