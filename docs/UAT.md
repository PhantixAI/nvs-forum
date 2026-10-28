# UAT Environment — uat.nitians.in

A single-site Discourse preview install, separate from production's multisite container.
It previews every push to `master` and every PR targeting `master`, so changes can be reviewed
before someone manually triggers a production deploy (see `DEPLOYMENT.md`).

Its Lightsail instance is **not always-on**: it's created on demand from a saved snapshot when a
deploy fires, reused across rapid successive deploys, and deleted once ~30 minutes pass with no
new deploy. AWS Lightsail bills the same flat price whether an instance is running or stopped, so
only deleting it actually avoids cost — that's why this uses create/delete rather than stop/start.

## How it works

- `.github/workflows/deploy-uat.yml` runs on a GitHub-hosted runner (not self-hosted, since the
  target instance may not exist at trigger time) on push to `master` and on `pull_request`
  `opened`/`synchronize` events targeting `master`.
- `concurrency: group: uat-deploy, cancel-in-progress: true` — a new trigger cancels any in-flight
  deploy. Combined with instance reuse, this means the 30-minute idle-delete clock only starts
  counting down from the *last* deploy, not the first.
- Each run determines whether to deploy `master`'s HEAD or a PR's HEAD SHA, and substitutes that
  into `containers/uat.yml`'s `<UAT_VERSION>` placeholder — so a PR preview actually reflects that
  PR's commits, not just whatever's on `master`.
- `containers/uat.yml` is `app.yml`'s single-site counterpart: no `config/multisite.yml` mount, no
  multisite hooks/nginx patches, points at its own database (`uat_nitians_forum`) and S3 bucket
  (`uat-nitians-forum-uploads`) on the same RDS instance/region as production.

## Checking current state / SSH access

```bash
# Does the instance currently exist?
aws lightsail get-instance --instance-name uat-nitians --profile personal

# If it exists, SSH in (uses the dedicated uat-nitians-key, not the account default key pair)
ssh -i /path/to/uat-nitians-key.pem ubuntu@uat.nitians.in

# Inside: same commands as production, container name is `uat` instead of `app`
sudo docker logs -f uat
sudo docker exec -it uat bash
```

If `get-instance` errors "not found," the instance has been idle-deleted; it will be recreated
automatically on the next push/PR trigger, or you can run `deploy-uat.yml` manually via
`gh workflow run deploy-uat.yml --ref master`.

## One-time setup (already done — for reference / disaster recovery)

If the snapshot, key pair, or static IP are ever lost and need to be redone:

1. **Dedicated SSH key pair** (scoped to just this instance, not the account-wide default):
   ```bash
   aws lightsail create-key-pair --key-pair-name uat-nitians-key --profile personal
   ```
   Save the returned private key **only** as the GitHub Actions secret `UAT_SSH_PRIVATE_KEY` — do
   not keep a local copy.

2. **Reserve a static IP** (stays constant across every future create/delete cycle):
   ```bash
   aws lightsail allocate-static-ip --static-ip-name uat-nitians-ip --profile personal
   ```

3. **Base instance**: create one Ubuntu 24.04 Lightsail instance, region `ap-south-1`, plan
   `small_2_0` (2 GB — confirm current plan naming/pricing in the console), using the
   `uat-nitians-key` key pair. Attach the static IP to it temporarily. Open ports 22/80/443.

4. **Base provisioning** (SSH in; same as production's first-time setup in `DEPLOYMENT.md`):
   ```bash
   sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
   sudo mkswap /swapfile && sudo swapon /swapfile
   echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
   sudo apt-get update && sudo apt-get install -y docker.io git
   sudo git clone https://github.com/discourse/discourse_docker.git /var/discourse
   sudo chmod 700 /var/discourse
   sudo sed -i '100a\        - sudo -H -E -u discourse git remote set-url origin $git_url' \
     /var/discourse/templates/web.template.yml
   sudo mkdir -p /var/discourse/shared/uat/ssl
   sudo mkdir -p /var/discourse/shared/uat/log/var-log
   ```

5. **Snapshot it**:
   ```bash
   aws lightsail create-instance-snapshot \
     --instance-name uat-nitians-base \
     --instance-snapshot-name uat-nitians-base-snapshot \
     --profile personal
   ```

6. **Tear down the base instance** (from here on, `deploy-uat.yml` creates/deletes instances
   itself):
   ```bash
   aws lightsail detach-static-ip --static-ip-name uat-nitians-ip --profile personal
   aws lightsail delete-instance --instance-name uat-nitians-base --profile personal
   ```

7. **DNS**: add an A record `uat.nitians.in` → the static IP from step 2, in whichever Route 53
   zone actually hosts `nitians.in` (verify this — `DEPLOYMENT.md`'s documented zone,
   `Z01839133PSJPBM657V7N`, is for `navodians.com`; confirm `nitians.in` is delegated there or has
   its own zone before assuming it's the same one).

8. **S3 bucket**: create `uat-nitians-forum-uploads`, separate from any production bucket.

9. **GitHub repo secrets**:
   - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — a dedicated IAM user scoped to the Lightsail
     actions the workflow needs (`CreateInstancesFromSnapshot`, `DeleteInstance`, `GetInstance`,
     `GetInstanceState`, `AttachStaticIp`, `DetachStaticIp`, `GetInstanceSnapshot`). Lightsail's
     IAM support for resource-ARN scoping is limited, so this will likely be action-scoped rather
     than restricted to just this one instance — an accepted tradeoff.
   - `UAT_SSH_PRIVATE_KEY` — from step 1.
   - `UAT_DISCOURSE_S3_ACCESS_KEY_ID` / `UAT_DISCOURSE_S3_SECRET_ACCESS_KEY` — scoped to just the
     UAT bucket (or reuse production's key if its IAM policy already covers the new bucket).
   - `NVS_GITHUB_PAT` and `DISCOURSE_DB_PASSWORD` are reused as-is from the existing production
     secrets (same GitHub repo, same RDS user).

## Database: one-time seed + mandatory PII scrub

`uat_nitians_forum` is a one-time clone of production's `nitians_forum`. It is **not** re-dumped
on every deploy — it persists and accumulates its own test data across every deploy/delete cycle,
independent of the UAT compute instance's lifecycle (the database lives on RDS, not on the
Lightsail instance).

```bash
# 1. Create the DB and restore a logical dump (safe against a live source --
#    pg_dump takes a consistent snapshot without locking production).
createdb -h navodians-pg15.cdey8w2mceyp.ap-south-1.rds.amazonaws.com -U phantixai_admin uat_nitians_forum

pg_dump -h navodians-pg15.cdey8w2mceyp.ap-south-1.rds.amazonaws.com \
  -U phantixai_admin --no-owner --no-acl -Fc nitians_forum -f /tmp/nitians_forum.dump

pg_restore -h navodians-pg15.cdey8w2mceyp.ap-south-1.rds.amazonaws.com \
  -U phantixai_admin -d uat_nitians_forum --no-owner --no-acl /tmp/nitians_forum.dump

rm /tmp/nitians_forum.dump
```

**Before the UAT container ever points at this database, scrub it of PII** (required, not
optional — `nitians_forum` is a real community DB with real user emails, IPs, and private
messages). At minimum, against `uat_nitians_forum` only (never against `nitians_forum`):

- Replace every user's email (and any pending/secondary email columns) with a synthetic one
  derived from their id, e.g. `user+<id>@uat.invalid`.
- Null out IP-address columns on `users`, `user_histories`, and similar tracking tables.
- Clear private message content (`posts.raw`/`cooked` for PM topics, plus `email_logs`,
  `email_tokens`, `user_api_keys`).
- Reset all passwords/sessions (new random `password_hash`/`salt`, clear `user_api_keys`,
  invalidate existing sessions) so no production credential carries over.

This is schema-aware; write it as a small, reviewed one-off script rather than improvising it
live against a copy that already has real PM content exposed.

No `multisite:migrate` involvement here — UAT isn't listed in any `multisite.yml`, so ordinary
single-site `db:migrate` (run automatically by the standard pups hook on every
`launcher bootstrap uat`) is all that's needed.
