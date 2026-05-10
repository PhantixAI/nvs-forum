# Deployment Guide — navodians.com

Production Discourse forum running on AWS Lightsail + RDS + S3 + CloudFront + SES.

## Infrastructure Overview

| Resource | Details |
|---|---|
| Compute | AWS Lightsail `navodians-forum` — `small_3_1` (2 GB RAM, Ubuntu 24.04) |
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

Push changes to `master` on `PhantixAI/nvs-forum`, then:

```bash
ssh -i ~/.ssh/lightsail-navodians.pem ubuntu@52.66.136.102
cd /var/discourse && sudo ./launcher rebuild app
```

Rebuild takes ~10–15 minutes. The site stays down during rebuild — plan accordingly.

## app.yml Credentials

Real credential values are stored in `/Users/deshraj/navodians-discourse/creds`.
The `containers/app.yml` in this repo uses `<PLACEHOLDER>` values — fill them in on the server before rebuilding.

| Placeholder | Where to find |
|---|---|
| `<GITHUB_PAT>` | Generate at GitHub → Settings → Developer Settings → Fine-grained tokens (Contents: read-only on `nvs-forum`) |
| `<DB_PASSWORD>` | creds file |
| `<SES_SMTP_USERNAME>` / `<SES_SMTP_PASSWORD>` | creds file |
| `<S3_ACCESS_KEY_ID>` / `<S3_SECRET_ACCESS_KEY>` | creds file |

## After Every Rebuild (until Let's Encrypt ECC cert is renewed)

Let's Encrypt rate-limited — proper ECC cert available after 2026-05-11. Until then, fix nginx after each rebuild:

```bash
sudo docker exec app bash -c '
  cp /shared/ssl/navodians.com.cer /shared/ssl/navodians.com_ecc.cer
  cp /shared/ssl/navodians.com.key /shared/ssl/navodians.com_ecc.key
  nginx -s reload
'
```

After May 11, run this inside the container to issue a proper ECC cert:
```bash
sudo docker exec -it app bash
/usr/local/bin/letsencrypt
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
