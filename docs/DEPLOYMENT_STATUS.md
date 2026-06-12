# Deployment Status

Last updated: 2026-06-13

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
- Verified `https://voicetype.y.dog/health/ready` returns HTTP 503 because
  `apple_signin_revoke_credentials=false`; all other checks are true.
- Verified `https://voicetype.y.dog/privacy` returns HTTP 200 for GET and HEAD.
- Verified `https://voicetype.y.dog/v1/billing/products` returns the three
  consumable credit products.

Latest real transcription smoke test:

- Date: 2026-06-05.
- Model: `gpt-4o-mini-transcribe`.
- Result: HTTP 200, transcript returned, ledger debited, temporary smoke user deleted.

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

Sign in with Apple revoke credentials are not yet configured on the VM; this is
why `/health/ready` returns HTTP 503 while `/health` stays healthy.

To rotate it later:

```bash
gcloud compute ssh voicetype-api --zone us-central1-a --project voicetype-y-dog-20260604 --command '
sudo sed -i "s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=YOUR_KEY_HERE/" /opt/voicetype/env/backend.env
cd /opt/voicetype/app
sudo docker compose -f deploy/gcp-vm/docker-compose.yml restart backend
'
```

Still required for App Store release:

- App Store Connect consumable IAP products.
- StoreKit sandbox/TestFlight validation.
- Sign in with Apple server-to-server credentials for token grant revocation on
  account deletion: `APPLE_SIGNIN_TEAM_ID`, `APPLE_SIGNIN_KEY_ID`, and the `.p8`
  through `APPLE_SIGNIN_PRIVATE_KEY` / `_B64` / `_PATH`.
