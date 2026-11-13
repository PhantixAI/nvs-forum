# UAT Environment — uat.navodians.com / uat.nitians.in / uat.iitians.in

A 3-site multisite Discourse preview install, mirroring production's multisite topology (same
hostnames-per-site pattern, same custom hooks/initializers/nginx patches, same per-site S3/CDN
routing) with one deliberate exception: its database is local PostgreSQL, not RDS. It previews
every push to `master` and every PR targeting `master`, so changes can be reviewed before someone
manually triggers a production deploy (see `DEPLOYMENT.md`).

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
- `containers/uat.yml` is `app.yml`'s multisite counterpart: same `DISCOURSE_HOSTNAME`/
  `DISCOURSE_HOSTNAME_ALIASES` pattern (one container, 3 hostnames), same `UNICORN_WORKERS: 2`,
  same per-site CDN/S3-fallback initializers and multisite nginx SSL patch, same
  `multisite:migrate` hook. The one structural difference from production: its database is a
  **local PostgreSQL container** (not production's RDS instance), backed by a persistent Lightsail
  block storage disk, so UAT workloads never share CPU/IO/connections with production (see
  "Database" below). Each site's uploads go to its own dedicated S3 bucket/CDN, fully isolated
  from production's buckets/CDN/SES identity (see "AWS resources" below).

## Manual start/stop

`.github/workflows/uat-control.yml` is a separate, `workflow_dispatch`-only workflow for bringing
UAT up or down on demand, independent of push/PR deploys and the 30-minute idle timer:

- **Run it from the Actions tab** (or `gh workflow run uat-control.yml -f action=start` /
  `-f action=stop`), picking `start` or `stop`.
- `start` optionally takes a `ref` input (branch/tag/SHA, defaults to `master`) and otherwise runs
  the exact same create-from-snapshot/bootstrap/verify steps as `deploy-uat.yml` — just without the
  idle-delete at the end, so it stays up until someone explicitly stops it.
- `stop` runs the same teardown `deploy-uat.yml` uses at the end of its idle wait (stop app, unmount
  disk, stop instance, detach disk + static IP, delete instance) — immediately, instead of waiting
  30 minutes.
- It shares `deploy-uat.yml`'s `uat-deploy` concurrency group with `cancel-in-progress: true`, so a
  manual `stop` immediately pre-empts a `deploy-uat.yml` run sitting in its idle wait rather than
  racing it, and vice versa.
- Both workflows carry near-identical secret-substitution and "verify the UAT sites are up" blocks
  — kept in lockstep deliberately; see the comments at the top of each file if they ever need to
  change again.

## Checking current state / SSH access

```bash
# Does the instance currently exist? (one instance serves all 3 hostnames)
aws lightsail get-instance --instance-name uat-nitians --profile personal

# If it exists, SSH in (uses the dedicated uat-nitians-key, not the account default key pair).
# Any of the 3 hostnames resolves to the same instance/static IP; uat.nitians.in is used here
# only because it's the longest-lived of the three.
ssh -i /path/to/uat-nitians-key.pem ubuntu@uat.nitians.in

# Inside: same commands as production, container name is `uat` instead of `app`
sudo docker logs -f uat
sudo docker exec -it uat bash
```

If `get-instance` errors "not found," the instance has been idle-deleted; it will be recreated
automatically on the next push/PR trigger, or you can run `deploy-uat.yml` manually via
`gh workflow run deploy-uat.yml --ref master`.

## One-time setup (already done — for reference / disaster recovery)

If the snapshot, key pair, static IP, or any of the AWS resources below are ever lost and need to
be redone:

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
   under that same mount, all 3 logical databases persist across every instance delete/recreate
   cycle even though the compute instance itself doesn't.

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

7. **DNS**: 3 A records (`uat.navodians.com`, `uat.nitians.in`, `uat.iitians.in`) → the static IP
   from step 2, one per site's own Route 53 hosted zone (all 3 domains have their own zone in this
   account, confirmed via `aws route53 list-hosted-zones --profile personal`):

   | Hostname | Zone | Zone ID |
   |---|---|---|
   | `uat.navodians.com` | `navodians.com` | `Z01839133PSJPBM657V7N` |
   | `uat.nitians.in` | `nitians.in` | `Z0746140Z037GXIG5GET` |
   | `uat.iitians.in` | `iitians.in` | `Z09039812NKNJUGOJXEOB` |

   Let's Encrypt issues one multi-SAN cert covering all 3 UAT hostnames on the instance itself —
   same mechanism production uses, no separate manual cert step needed for the app's own TLS.

8. **S3 buckets** (3, one per site, separate from any production bucket):
   `uat-navodians-forum-uploads`, `uat-nitians-forum-uploads`, `uat-iitians-forum-uploads`.

9. **CloudFront distributions** (3, new — UAT previously had no CDN): `cdn.uat.navodians.com`,
   `cdn.uat.nitians.in`, `cdn.uat.iitians.in`, each fronting its own bucket above via Origin Access
   Control (not legacy OAI), each with its own ACM certificate (requested in `us-east-1`,
   regardless of the bucket's `ap-south-1` region — a CloudFront/ACM requirement) and its own DNS
   CNAME pointing at the distribution's `*.cloudfront.net` domain, in the same zone as that site's
   A record above.

10. **SES identity**: a dedicated domain identity `uat.navodians.com` (region `ap-south-1`), with
    its own DKIM/SPF DNS records (added to the `navodians.com` zone once SES returns them) — not
    shared with production's `navodians.com`/`nitians.in`/`iitians.in` identities. All 3 UAT sites
    send through this one identity (`DISCOURSE_SMTP_DOMAIN: uat.navodians.com` in
    `containers/uat.yml`), mirroring production's single-global-SMTP-domain pattern.

11. **GitHub repo secrets**:
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
    - `UAT_DISCOURSE_S3_ACCESS_KEY_ID` / `UAT_DISCOURSE_S3_SECRET_ACCESS_KEY` — one IAM user/policy
      scoped to cover **all 3** UAT buckets from step 8 (one principal, not three, per
      least-privilege guidance — three near-identical scoped-to-one-bucket principals buy nothing
      extra for a low-traffic preview environment).
    - `UAT_DISCOURSE_SMTP_USERNAME` / `UAT_DISCOURSE_SMTP_PASSWORD` — SMTP credentials generated
      against the dedicated SES identity from step 10. These replace UAT's previous reuse of
      production's `DISCOURSE_SMTP_USERNAME`/`DISCOURSE_SMTP_PASSWORD` secrets — infra isolation
      from production now extends to email sending, not just storage.
    - `NVS_GITHUB_PAT` is reused as-is from the existing production secret (same GitHub repo).
      `DISCOURSE_DB_PASSWORD` is **not** used by UAT — its database is local, not RDS.

## Database: local PostgreSQL, 3 logical databases, one-time seed + mandatory PII scrub

UAT's database is **not** production's shared RDS instance — `containers/uat.yml` includes
`templates/postgres.template.yml`, so the UAT instance runs its own local PostgreSQL container,
with data stored at `/shared/postgres_data` (i.e. under the `/var/discourse/shared/uat` bind mount,
which is the persistent disk described above, not the instance's ephemeral root volume). This is
what keeps UAT's bootstrap/migration/test load from ever competing with production for CPU, IOPS,
or connection slots on the shared `db.t4g.micro` RDS instance.

Unlike today's old single-database setup, UAT is now genuinely **multisite**: that one local
Postgres server hosts 3 logical databases — `uat_navodians`, `uat_nitians`, `uat_iitians` — all
owned by the same local `discourse` role. `templates/postgres.template.yml` (vendored from
`discourse_docker`, not in this repo) only provisions one database by default, named via the
`db_name` param (`uat_navodians` here — see `containers/uat.yml`'s `params:` block); the other two
are created by a new `after_postgres` hook in `containers/uat.yml`, the pups-supported insertion
point immediately after `postgres.template.yml`'s own default-database creation step (see
`discourse_docker`'s `samples/data.yml` for the same pattern, there used to set a password). That
hook's `createdb ... || true` / `create extension if not exists` pattern makes it safe to run on
every container start, not just the first.

`config/multisite.uat.yml` (committed to this repo, plain, no secret — UAT's local Postgres uses
trust/peer auth over the Unix socket, so there's nothing secret to keep out of git, unlike
production's RDS-backed `config/multisite.yml`) names all 3 databases and their host names. An
`after_code` hook in `containers/uat.yml` copies it over `config/multisite.yml` inside the UAT
build only — the repo's own `config/multisite.yml` (production's) is never touched. With that file
in place, Discourse boots in multisite mode and a new `after_db_migrate` hook runs
`multisite:migrate` for real, across all 3 databases — unlike the old single-site setup, which only
ever ran plain `db:migrate`.

The databases were seeded **once per site**, directly on the persistent disk, from a `pg_dump` of
production's corresponding database (`nitians_forum`, `navodians_forum`, `iitians_forum` — taken
over SSH from inside production's own `app` container, a consistent snapshot that doesn't lock
production), restored into the matching local database (`uat_nitians`, `uat_navodians`,
`uat_iitians`, created with `-O discourse` directly, avoiding a `REASSIGN OWNED BY` step that fails
on objects Postgres itself requires) and then PII-scrubbed in place before the UAT container was
ever pointed at it. None of the 3 is re-dumped on later deploys — each persists and accumulates its
own test data across every subsequent deploy/delete cycle, independent of the compute instance's
lifecycle, because the disk (not the instance) is what carries them forward.

**The PII scrub is required, not optional** — these are real community databases with real user
emails, IPs, and private messages. What was scrubbed, against each local database only (never
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

**Additionally, each seeded site's `s3_upload_bucket` and `s3_cdn_url` site settings are repointed**
at that site's own UAT-dedicated bucket/CDN (from the AWS resources above) instead of leaving them
pointed at production's — otherwise UAT would silently read/write uploads against production's live
bucket. As before, pre-scrub historical upload *files* themselves are not copied, so old inline
images will still 404 on UAT; this is a known, unchanged, accepted limitation.

If a disk is ever lost and needs reseeding, repeat this process (dump → restore with `-O discourse`
→ scrub → repoint bucket/CDN settings) for all 3 sites against their respective local databases
(not RDS) — see git history around commits `5a00bdd5f52`/`c4727b52757`/`e548982303e` for the exact
restore-ownership and PII-scrub details from when this was first done for `nitians_forum`.
