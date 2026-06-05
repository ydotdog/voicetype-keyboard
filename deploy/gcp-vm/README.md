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

## Backup and Restore

Billing data lives in the Postgres volume under `/opt/voicetype/data/postgres`. Production should keep the VM disk attached to a scheduled persistent disk snapshot policy and periodically verify that snapshots are being created.

Current production baseline:

- Snapshot policy: `voicetype-daily-snapshot`.
- Retention: 14 daily snapshots.
- Protected data: `/opt/voicetype/data`, including Postgres and Caddy state.

Verify snapshot policy attachment:

```bash
gcloud compute disks describe voicetype-api \
  --zone us-central1-a \
  --project voicetype-y-dog-20260604 \
  --format='value(resourcePolicies[])'
```

List recent snapshots:

```bash
gcloud compute snapshots list \
  --project voicetype-y-dog-20260604 \
  --filter='sourceDisk~voicetype-api' \
  --sort-by='~creationTimestamp' \
  --limit=10
```

Restore drill outline:

1. Stop writes to the existing backend or route traffic away from it.
2. Create a replacement disk from a known-good snapshot.
3. Attach or boot a replacement VM with the restored disk.
4. Start Docker Compose and confirm Postgres is healthy.
5. Run `/health/ready`, then a billing ledger read for a known test user.
6. Repoint DNS or the static IP only after the restored backend is verified.
