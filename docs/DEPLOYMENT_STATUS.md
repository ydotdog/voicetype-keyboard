# Deployment Status

Last updated: 2026-06-04

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

Current public smoke test:

```bash
curl http://34.10.43.168/health
```

Expected response:

```json
{"ok":true,"service":"voicetype-api","model":"gpt-4o-mini-transcribe","database":"postgres","storekit_verification_mode":"strict"}
```

## DNS

Target production hostname: `voicetype.y.dog`.

Current blocker: `y.dog` is delegated to Cloudflare nameservers:

- `nena.ns.cloudflare.com`
- `jarred.ns.cloudflare.com`

So DNS records must be changed in Cloudflare, not name.com, unless the domain's authoritative nameservers are moved away from Cloudflare. The required DNS change is:

- Type: `A`
- Name: `voicetype`
- Value: `34.10.43.168`
- Proxy: DNS only is simplest for first TLS validation; Cloudflare proxy can be enabled later after origin HTTPS is confirmed.

After DNS points at the VM:

```bash
gcloud compute ssh voicetype-api --zone us-central1-a --project voicetype-y-dog-20260604 --command '
sudo cp /opt/voicetype/app/deploy/gcp-vm/Caddyfile.https /opt/voicetype/config/Caddyfile
cd /opt/voicetype/app
sudo docker compose -f deploy/gcp-vm/docker-compose.yml restart caddy
'
```

Then verify:

```bash
curl https://voicetype.y.dog/health
```

## Remaining Secrets

`OPENAI_API_KEY` is intentionally blank until the production key is provided.

To install it later:

```bash
gcloud compute ssh voicetype-api --zone us-central1-a --project voicetype-y-dog-20260604 --command '
sudo sed -i "s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=YOUR_KEY_HERE/" /opt/voicetype/env/backend.env
cd /opt/voicetype/app
sudo docker compose -f deploy/gcp-vm/docker-compose.yml restart backend
'
```

Also still required for production purchase grants:

- `APPLE_APP_APPLE_ID` in `/opt/voicetype/env/backend.env`.
- App Store Connect consumable IAP products.
- StoreKit sandbox/TestFlight validation.
