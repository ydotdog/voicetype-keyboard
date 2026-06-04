# Deployment Status

Last updated: 2026-06-05

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

- Credit packs: `$1`, `$5`, `$20` consumable StoreKit products.
- `COST_MARKUP_BPS=7143`, covering standard 30% App Store commission plus 20% target profit.
- `ALLOW_DEV_CREDIT=false` in production.

Current public smoke tests:

```bash
curl http://34.10.43.168/health
curl https://voicetype.y.dog/health
curl https://voicetype.y.dog/health/ready
```

Expected response:

```json
{"ok":true,"service":"voicetype-api","model":"gpt-4o-mini-transcribe","database":"postgres","storekit_verification_mode":"strict"}
```

`/health/ready` should return HTTP 200 with all production checks true:

- JWT secret configured.
- OpenAI API key configured.
- Postgres reachable.
- StoreKit strict verification enabled.
- `appAccountToken` required.
- Apple App ID and root certificate material configured.
- Dev credit disabled.

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

To rotate it later:

```bash
gcloud compute ssh voicetype-api --zone us-central1-a --project voicetype-y-dog-20260604 --command '
sudo sed -i "s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=YOUR_KEY_HERE/" /opt/voicetype/env/backend.env
cd /opt/voicetype/app
sudo docker compose -f deploy/gcp-vm/docker-compose.yml restart backend
'
```

Still required for production purchase grants:

- `APPLE_APP_APPLE_ID` in `/opt/voicetype/env/backend.env`.
- App Store Connect consumable IAP products.
- StoreKit sandbox/TestFlight validation.
