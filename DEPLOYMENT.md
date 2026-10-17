# Deployment Guide — navodians.com

Production Discourse forum running on AWS Lightsail + RDS + S3 + CloudFront + SES.

## Infrastructure Overview

| Resource | Details |
|---|---|
| Compute | AWS Lightsail `navodians-forum-4gb` — `medium_3_1` (4 GB RAM, Ubuntu 24.04) |
| IP | `52.66.136.102` (static) |
| Database | RDS PostgreSQL 15 — `navodians-pg15.cdey8w2mceyp.ap-south-1.rds.amazonaws.com` |
| Storage | S3 `navodians-forum-uploads` (assets/uploads), `navodians-forum-backups` |
| CDN | CloudFront `E2HP66UZS7GMN7` → `cdn.navodians.com` |
| Email | Amazon SES ap-south-1 (production access granted) |
| DNS | Route 53 hosted zone `navodians.com` |
| Region | `ap-south-1` (Mumbai) |

## SSH Access

```bash
# Download fresh each session — do NOT store permanently
aws lightsail download-default-key-pair --profile personal --output json \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['privateKeyBase64'])" \
  > /tmp/ls_key.pem && chmod 600 /tmp/ls_key.pem

ssh -i /tmp/ls_key.pem ubuntu@52.66.136.102
```

## First-Time Setup (already done — for reference)

1. Add swap and install Docker:
   ```bash
   sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
   sudo mkswap /swapfile && sudo swapon /swapfile
   echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
   sudo apt-get update && sudo apt-get install -y docker.io git
   ```

2. Clone discourse_docker:
   ```bash
   sudo git clone https://github.com/discourse/discourse_docker.git /var/discourse
   sudo chmod 700 /var/discourse
   ```

3. Copy `containers/app.yml` (fill in real credentials from creds file):
   ```bash
   sudo cp app.yml /var/discourse/containers/app.yml
   # Edit: replace all <PLACEHOLDER> values with real credentials
   sudo nano /var/discourse/containers/app.yml
   ```

4. Create host volume directories:
   ```bash
   sudo mkdir -p /var/discourse/shared/standalone/ssl
   sudo mkdir -p /var/discourse/shared/standalone/log/var-log
   ```

5. Modify `web.template.yml` to support private git repo (run once):
   ```bash
   sudo sed -i '100a\        - sudo -H -E -u discourse git remote set-url origin $git_url' \
     /var/discourse/templates/web.template.yml
   ```

6. Bootstrap:
   ```bash
   cd /var/discourse && sudo ./launcher rebuild app
   ```

## Deploying Custom Changes

Deploys are automated via `.github/workflows/deploy.yml`, which runs on a self-hosted GitHub
Actions runner on this same Lightsail box. **Every push to `master` triggers it automatically**
— there is no manual SSH step for a normal deploy anymore. It:

1. Writes `containers/app.yml`/`config/multisite.yml` with real secrets injected.
2. Runs `sudo ./launcher bootstrap app` to build the new image — **the site stays up** during
   this step, since bootstrap builds into a new container without touching the running one.
3. Swaps the container (`launcher destroy` + `launcher start`) — brief downtime, ~30s.
4. Waits for nginx and curl-checks all three domains before finishing; fails the workflow (and
   leaves the old container running) if anything doesn't come up.

Before a commit can even reach `master`, `.github/workflows/bootstrap-check.yml` must pass — it
runs the same `pnpm install --frozen-lockfile` command the bootstrap step depends on, inside the
real `discourse/base` image, as a required PR check. This exists because a pnpm/TypeScript
tooling upgrade from upstream Discourse broke that exact step in production on 2026-10-17 with no
earlier warning (see the revert commits around `570ffdda808`/`4368431eb4b` for the root cause).

A manual `ssh` + `sudo ./launcher rebuild app` (as in First-Time Setup above) is only needed for
one-off recovery, not routine deploys.

## app.yml Credentials

Real credential values are stored in `/Users/deshraj/navodians-discourse/creds`.
The `containers/app.yml` in this repo uses `<PLACEHOLDER>` values — fill them in on the server before rebuilding.

| Placeholder | Where to find |
|---|---|
| `<GITHUB_PAT>` | Generate at GitHub → Settings → Developer Settings → Fine-grained tokens (Contents: read-only on `nvs-forum`) |
| `<DB_PASSWORD>` | creds file |
| `<SES_SMTP_USERNAME>` / `<SES_SMTP_PASSWORD>` | creds file |
| `<S3_ACCESS_KEY_ID>` / `<S3_SECRET_ACCESS_KEY>` | creds file |

## SSL Certificate Management

Let's Encrypt RSA cert issued 2026-05-11, expires 2026-08-09. Auto-renews via container cron job.

### If nginx fails to start after a rebuild (ECC cert issue)

The bootstrap runs `letsencrypt` and may fail to issue the ECC cert (rate limit: 5 certs/7 days).
Fix by copying the RSA cert to the ECC paths:

```bash
sudo docker exec app bash -c '
  cp /shared/ssl/navodians.com.cer /shared/ssl/navodians.com_ecc.cer
  cp /shared/ssl/navodians.com.key /shared/ssl/navodians.com_ecc.key
  sv reload nginx
'
```

### Re-issuing cert (after rate limit resets or cert expires)

```bash
sudo docker exec app bash -c '/usr/local/bin/letsencrypt'
# Then fix ECC paths as above
```

### Server migration — protect certs before bootstrap

Bootstrap overwrites cert files if it can't issue a new one. Always backup before rebuilding on a new server:

```bash
sudo cp /var/discourse/shared/standalone/ssl/navodians.com.cer /tmp/navodians.com.cer.bak
sudo cp /var/discourse/shared/standalone/ssl/navodians.com.key /tmp/navodians.com.key.bak
# After bootstrap, if certs are empty, restore:
sudo cp /tmp/navodians.com.cer.bak /var/discourse/shared/standalone/ssl/navodians.com.cer
sudo cp /tmp/navodians.com.key.bak /var/discourse/shared/standalone/ssl/navodians.com.key
```

## Useful Commands

```bash
# View live logs
sudo docker logs -f app

# Enter running container
sudo docker exec -it app bash

# Check Sidekiq
# Browser: https://navodians.com/sidekiq (admin only)

# Rails console
sudo docker exec -it app bash -c 'cd /var/www/discourse && bundle exec rails c'

# Restart unicorn without full rebuild
sudo docker exec app bash -c 'sv restart unicorn'

# Check nginx config
sudo docker exec app bash -c 'nginx -t'

# View nginx errors
sudo docker exec app bash -c 'tail -f /var/log/nginx/error.log'
```

## S3 Asset Upload (if CDN assets go missing after rebuild)

Brotli JS assets must exist at both `.br.js` paths in S3. Run from local machine:

```bash
# Re-upload brotli assets from container to S3
python3 scripts/upload_brotli_assets.py  # see script for details
```

CloudFront cache invalidation after uploads:
```bash
aws cloudfront create-invalidation \
  --distribution-id E2HP66UZS7GMN7 \
  --paths "/assets/*" "/assets/br/*" "/assets/js/plugins/*" \
  --profile personal
```

## DNS (Route 53)

All DNS managed in Route 53 hosted zone `Z01839133PSJPBM657V7N`:
- `navodians.com` A → `52.66.136.102`
- `cdn.navodians.com` CNAME → `dbvmcj757mpk.cloudfront.net`
- `bounce.navodians.com` MX → `feedback-smtp.ap-south-1.amazonses.com` (SES bounce handling)
- 3x DKIM CNAME records for SES email signing
