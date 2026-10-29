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
  multisite hooks/nginx patches. Its database is a **local PostgreSQL container** (not production's
  RDS instance) backed by a persistent Lightsail block storage disk, so UAT workloads never share
  CPU/IO/connections with production (see "Database" below). Its uploads go to their own S3 bucket
  (`uat-nitians-forum-uploads`).

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

2a. **Create the persistent DB disk** (stays constant across every future create/delete cycle,
    same as the static IP — this is what lets the database survive the instance's own idle-delete):
   ```bash
   aws lightsail create-disk \
     --disk-name uat-nitians-db-disk \
     --availability-zone ap-south-1a \
     --size-in-gb 8 \
     --profile personal
   ```
   `deploy-uat.yml` attaches this at `/dev/xvdf` and mounts it at `/var/discourse/shared/uat` on
   every instance create, formatting it with `mkfs.ext4` only the very first time (detected via
   `blkid`). Since PostgreSQL's data directory (`/shared/postgres_data` inside the container) lives
   under that same mount, the database persists across every instance delete/recreate cycle even
   though the compute instance itself doesn't.

3. **Base instance**: create one Ubuntu 24.04 Lightsail instance, region `ap-south-1`, plan
   `small_3_1` (2 GB RAM, 2 vCPU, $12/mo — current Lightsail bundle naming as of 2026-10;
   `small_2_0` no longer exists), using the `uat-nitians-key` key pair. Attach the static IP to it
   temporarily. Open ports 22/80/443.

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
     `GetInstanceState`, `AttachStaticIp`, `DetachStaticIp`, `GetInstanceSnapshot`, `CreateDisk`,
     `GetDisk`, `AttachDisk`, `DetachDisk`, `OpenInstancePublicPorts`, `PutInstancePublicPorts`,
     `GetInstancePortStates`, `StopInstance`). The last four are needed for opening port 443 on a
     freshly-created instance and for stopping the instance before `DetachDisk` (AWS requires the
     instance to be stopped before its disk can be detached). Lightsail's IAM support for
     resource-ARN scoping is
     limited, so this will likely be action-scoped rather than restricted to just this one
     instance/disk — an accepted tradeoff.
   - `UAT_SSH_PRIVATE_KEY` — from step 1.
   - `UAT_DISCOURSE_S3_ACCESS_KEY_ID` / `UAT_DISCOURSE_S3_SECRET_ACCESS_KEY` — scoped to just the
     UAT bucket (or reuse production's key if its IAM policy already covers the new bucket).
   - `NVS_GITHUB_PAT` is reused as-is from the existing production secret (same GitHub repo).
     `DISCOURSE_DB_PASSWORD` is **not** used by UAT — its database is local, not RDS.

## Database: local PostgreSQL, one-time seed + mandatory PII scrub

UAT's database is **not** production's shared RDS instance — `containers/uat.yml` includes
`templates/postgres.template.yml`, so each UAT instance runs its own local PostgreSQL container,
with data stored at `/shared/postgres_data` (i.e. under the `/var/discourse/shared/uat` bind mount,
which is the persistent disk described above, not the instance's ephemeral root volume). This is
what keeps UAT's bootstrap/migration/test load from ever competing with production for CPU, IOPS,
or connection slots on the shared `db.t4g.micro` RDS instance.

The database was seeded **once**, directly on the persistent disk, from a `pg_dump` of production's
`nitians_forum` (taken over SSH from inside production's own `app` container, a consistent
snapshot that doesn't lock production), restored into the local `discourse` database and then
PII-scrubbed in place before the UAT container was ever pointed at it. It is **not** re-dumped on
later deploys — it persists and accumulates its own test data across every subsequent deploy/delete
cycle, independent of the compute instance's lifecycle, because the disk (not the instance) is what
carries it forward.

**The PII scrub is required, not optional** — `nitians_forum` is a real community DB with real user
emails, IPs, and private messages. What was scrubbed, against the local `discourse` DB only (never
against production):

- Every row in `user_emails` (keyed by row id, since some users have 2 rows) replaced with a
  synthetic `user+<user_id>+<id>@uat.invalid`; same pattern for `email_tokens`/`email_change_requests`.
- `email_login_codes`, `email_logs`, `incoming_emails`, `screened_emails` fully deleted (no safe
  per-row re-keying, and not needed for a preview env).
- IP columns nulled on `users`, `incoming_links`, `user_histories`.
- `user_ip_address_histories` fully deleted; `user_auth_tokens`, `user_auth_token_logs`,
  `user_api_keys`, `user_second_factors`, `user_security_keys` fully deleted (forces fresh
  login/2FA/API-key setup on UAT, no production session/credential carries over).
- `user_passwords.password_hash`/`password_salt` randomized per row.
- Private-message topic content (`posts.raw`/`cooked`/`raw_email`, `topics.title`/`fancy_title`/`excerpt`
  for `archetype = 'private_message'`) redacted.
- DM-only chat content redacted (`chat_messages.message`/`cooked` where the channel's
  `chatable_type = 'DirectMessage'` — public Category-backed chat channels are left alone, since
  that's public forum content, not PII).

If the disk is ever lost and needs reseeding, repeat this against the local `discourse` DB on the
UAT instance (not RDS) — see git history for the exact scrub script.

No `multisite:migrate` involvement here — UAT isn't listed in any `multisite.yml`, so ordinary
single-site `db:migrate` (run automatically by the standard pups hook on every
`launcher bootstrap uat`) is all that's needed.
