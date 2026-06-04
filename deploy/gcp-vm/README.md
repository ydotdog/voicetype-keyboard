# GCP VM Deployment

This deployment runs the VoiceType backend on a single Debian VM with Docker Compose:

- `backend`: FastAPI app.
- `postgres`: local Postgres database with a persistent host volume.
- `caddy`: reverse proxy. Use `Caddyfile.http` before DNS points at the VM, then switch to `Caddyfile.https` for Let's Encrypt.

Expected host paths:

- `/opt/voicetype/app`: checked out or copied application source.
- `/opt/voicetype/env/backend.env`: backend runtime environment.
- `/opt/voicetype/env/db.env`: Postgres environment.
- `/opt/voicetype/data`: persistent Postgres and Caddy data.
- `/opt/voicetype/config/Caddyfile`: active Caddy config.

Useful commands on the VM:

```bash
cd /opt/voicetype/app
sudo docker compose -f deploy/gcp-vm/docker-compose.yml up -d --build
sudo docker compose -f deploy/gcp-vm/docker-compose.yml ps
sudo docker compose -f deploy/gcp-vm/docker-compose.yml logs -f backend
```

After DNS `voicetype.y.dog -> VM static IP` is live:

```bash
sudo cp /opt/voicetype/app/deploy/gcp-vm/Caddyfile.https /opt/voicetype/config/Caddyfile
cd /opt/voicetype/app
sudo docker compose -f deploy/gcp-vm/docker-compose.yml restart caddy
```
