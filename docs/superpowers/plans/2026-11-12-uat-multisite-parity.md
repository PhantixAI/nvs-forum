# UAT → Production Parity (Multisite) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make UAT (`uat.navodians.com` / `uat.nitians.in` / `uat.iitians.in`) structurally and
behaviorally identical to production's multisite topology — same hostnames-per-site pattern, same
custom hooks/initializers/nginx patches, same per-site S3/CDN routing, same `multisite:migrate` —
while keeping UAT's database on local PostgreSQL (3 logical databases, not RDS) and keeping every
other piece of infra (S3, CDN, SES, certs) fully isolated from production.

**Architecture:** Repo-side changes (`config/multisite.uat.yml`, `containers/uat.yml`,
`.github/workflows/deploy-uat.yml`, `.github/workflows/uat-control.yml`, `docs/UAT.md`) land as a
normal reviewable PR with no live-infra dependency. AWS-side changes (3 S3 buckets, 3 CloudFront
distributions + ACM certs, 2 new Route 53 A records + 3 CDN CNAMEs, 1 new SES domain identity, 1
widened IAM policy) are provisioned via `aws` CLI following the `aws-core` plugin's skills, gated
behind explicit per-category user confirmation before each mutating call. Seeding
(`navodians_forum`/`iitians_forum` → UAT) reuses the exact `pg_dump`-from-production +
PII-scrub-in-place process already used for `nitians_forum`, gated behind confirmation since it
touches production (even read-only). A final live-deploy verification closes the loop.

**Tech Stack:** `discourse_docker` (pups-templated YAML), AWS Lightsail/S3/CloudFront/Route
53/SES/IAM via `aws` CLI (`--profile personal`, region `ap-south-1`), GitHub Actions, PostgreSQL
(local, trust/peer auth over Unix socket).

**Spec:** `docs/superpowers/specs/2026-11-12-uat-multisite-parity-design.md`

## Global Constraints

- Database backend stays local PostgreSQL — never RDS. This is explicit, non-negotiable, and the
  one deliberate production/UAT structural difference.
- AWS CLI: `--profile personal`, region `ap-south-1`, same pattern as `docs/UAT.md`'s existing
  one-time setup and `DEPLOYMENT.md`.
- Reuse existing AWS resource *names* as-is, do not rename: `uat-nitians` (instance),
  `uat-nitians-key` (key pair), `uat-nitians-db-disk` (disk), `uat-nitians-base-snapshot`
  (snapshot), `uat-nitians-ip` (static IP).
- No `www.` hostname aliases for UAT (production has them; UAT deliberately doesn't — it's a test
  environment).
- No S3-backed backups for UAT — do not set `DISCOURSE_BACKUP_LOCATION: s3` or
  `DISCOURSE_S3_BACKUP_BUCKET` in `containers/uat.yml`.
- `config/multisite.yml` (production's, RDS-backed, secret-filled-at-deploy-time) is never
  modified by this work — `config/multisite.uat.yml` is a wholly separate, always-plain,
  always-committed file.
- Before any AWS mutation that creates/changes billable or hard-to-reverse infrastructure
  (S3 buckets, CloudFront distributions, Route 53 records in the shared hosted zones, SES
  identity verification, IAM policy/user changes), before adding any new GitHub Actions secret,
  and before running `pg_dump` against production (even read-only) — stop and get the user's
  explicit go-ahead for that category of action first. Read-only AWS calls (`list-*`, `get-*`,
  `describe-*`) never need this.
- Resource decisions already locked in during planning (not open questions for the implementer):
  - IAM: **one** IAM user, policy widened to cover all 3 new UAT bucket ARNs (reuses the existing
    `UAT_DISCOURSE_S3_ACCESS_KEY_ID`/`UAT_DISCOURSE_S3_SECRET_ACCESS_KEY` GitHub secrets — no new
    S3 secret needed), per `aws-security` least-privilege guidance (one scoped principal beats
    three near-identical ones for a low-traffic preview environment).
  - SES: new domain identity `uat.navodians.com` (own DKIM/SPF, independent of the `navodians.com`
    /`nitians.in`/`iitians.in` identities production uses). New GitHub secrets
    `UAT_DISCOURSE_SMTP_USERNAME` / `UAT_DISCOURSE_SMTP_PASSWORD` replace today's reuse of
    production's `DISCOURSE_SMTP_USERNAME`/`DISCOURSE_SMTP_PASSWORD` secrets in both
    `deploy-uat.yml` and `uat-control.yml`. `DISCOURSE_SMTP_DOMAIN: uat.navodians.com` in
    `containers/uat.yml` (one global SMTP domain for the whole multisite install, mirroring
    production's `app.yml` pattern).
  - Route 53 zone IDs confirmed via `aws route53 list-hosted-zones` (read-only, already run):
    `navodians.com` → `Z01839133PSJPBM657V7N`, `nitians.in` → `Z0746140Z037GXIG5GET`,
    `iitians.in` → `Z09039812NKNJUGOJXEOB`. All three domains already have their own hosted zones
    in this account — no delegation ambiguity to resolve.
  - The `patch-configure-ssl` step (removes the single-site www→apex nginx redirect block that
    would otherwise break UAT's second/third hostname) is **kept** — it is load-bearing for
    multisite UAT working at all, not just a parity nicety. The per-domain `www`→apex redirect
    block (`25-multisite.conf` in `app.yml`) is **omitted** for UAT, with a comment explaining why:
    UAT has no `www.uat.*` hostnames (Global Constraints above), so the block would have zero
    inputs to ever match — keeping a no-op block adds confusion with no coverage benefit.
  - The open technical risk flagged in the spec (`postgres.template.yml` only provisions one local
    DB) is resolved: `discourse_docker`'s `templates/postgres.template.yml` exposes a named pups
    hook point `postgres` (its final `create_db`-running `exec` step is tagged `hook: postgres`),
    and `discourse_docker/samples/data.yml` demonstrates the supported pattern — a template/container
    file adds `hooks: { after_postgres: [...] }` to run additional steps immediately after the
    default database is created. `containers/uat.yml` uses this same `after_postgres` hook to
    `createdb` the two extra logical databases (idempotently) under the same `discourse` role,
    with the same extensions (`hstore`, `pg_trgm`, `vector`) each default `create_db` already
    creates for the first database.

## Review Focus

- **Idempotent `after_postgres` hook across every reboot, not just the first.** The hook runs on
  *every* container start (it's not a one-time bootstrap-only step), so `createdb uat_nitians`
  must not fail the whole boot on the 2nd/3rd/Nth run once the databases already exist. Covered in
  Task 2's verification step (two consecutive `launcher bootstrap uat` runs must both succeed).
- **Per-site S3/CDN cross-wiring during seeding.** If any one of the 3 sites' `s3_upload_bucket`/
  `s3_cdn_url` site settings is missed or wrong during seeding, that site's uploads silently keep
  hitting the wrong bucket (possibly production's) instead of erroring loudly. Covered in Task 7's
  explicit per-site verification query before considering seeding done.
- **`patch-configure-ssl` silently not matching.** If the text block it looks for ever drifts from
  what upstream `discourse_docker`'s `configure-ssl` actually contains, the patch becomes a no-op
  and `uat.nitians.in`/`uat.iitians.in` start 301-redirecting to `uat.navodians.com` — while
  `uat.navodians.com` itself still returns 200, masking the failure from a naive single-host health
  check. Covered in Task 9's verification, which curls and checks the response code for **all 3**
  hostnames, not just one, and checks the build log for `patch-configure-ssl`'s own
  patched/already-patched/not-found message.
- **`uat-control.yml` drifting out of sync with `deploy-uat.yml`.** Both workflows carry a near-
  identical "write `containers/uat.yml` with secrets" placeholder-substitution block and a
  "verify … is up" step; `uat-control.yml` is not named in the spec but shares both blocks
  byte-for-byte today, so skipping it breaks the manual start/stop workflow even though the
  automated deploy workflow works. Covered by Task 4 (added during planning; mirrors Task 3).
- **Hook-ordering race between `after_postgres` and `after_db_migrate`.** `multisite:migrate`
  (`after_db_migrate`) must only run after the two extra databases exist (`after_postgres`), or
  migration fails trying to connect to databases that don't exist yet. Covered in Task 2's
  verification step, which confirms (via `pups`' documented phase ordering and an actual bootstrap
  run) that `after_postgres` always fires before `after_db_migrate`.

---

## File Structure

| File | Responsibility |
|---|---|
| `config/multisite.uat.yml` (new) | Plain, committed, final multisite DB config for UAT's 3 local logical databases — no secrets. |
| `containers/uat.yml` (modify) | UAT's pups container definition: hostnames, hooks (postgres DB creation, multisite config copy, multisite migrate), worker count, CDN/S3 env, copied initializers, nginx SSL patch. |
| `.github/workflows/deploy-uat.yml` (modify) | Automated deploy: new secret substitutions, 3-hostname verification loop. |
| `.github/workflows/uat-control.yml` (modify) | Manual start/stop: same secret substitutions and verification loop, kept in lockstep with `deploy-uat.yml`. |
| `docs/UAT.md` (rewrite) | Describes the 3-site architecture, 3-DB database section, one-time setup (DNS/S3/CDN/SES), seed/scrub-for-3-sites section. |

No other files are expected to change. AWS resources and GitHub secrets are provisioned
out-of-band (CLI/console), not as repo files.

---

### Task 1: `config/multisite.uat.yml`

**Files:**
- Create: `config/multisite.uat.yml`

**Interfaces:**
- Produces: a 3-key YAML file (`navodians`, `nitians`, `iitians`) consumed by Task 2's
  `after_code` hook (copies it to `config/multisite.yml` inside the UAT image) and by Task 7's
  seeding (names the 3 logical databases it must create/restore into: `uat_navodians`,
  `uat_nitians`, `uat_iitians`).

- [ ] **Step 1: Create `config/multisite.uat.yml`** with exactly this content (verbatim from the
  spec's "Database" section — no placeholders):

```yaml
navodians:
  adapter: postgresql
  database: uat_navodians
  username: discourse
  host: ""            # unix socket, same as single-site default
  pool: 5
  timeout: 5000
  host_names:
    - uat.navodians.com

nitians:
  adapter: postgresql
  database: uat_nitians
  username: discourse
  host: ""
  pool: 5
  timeout: 5000
  host_names:
    - uat.nitians.in

iitians:
  adapter: postgresql
  database: uat_iitians
  username: discourse
  host: ""
  pool: 5
  timeout: 5000
  host_names:
    - uat.iitians.in
```

- [ ] **Step 2: Verify the file is valid YAML and matches `config/multisite.yml`'s existing shape**

Run: `ruby -ryaml -e "pp YAML.load_file('config/multisite.uat.yml')"`
Expected: a 3-key hash, each value a hash with `adapter`/`database`/`username`/`host`/`pool`/
`timeout`/`host_names` keys, matching the structure of `config/multisite.yml` (read that file for
comparison — same keys, different `database`/`host`/`username`/`host_names` values, no
`password` key since UAT uses trust/peer auth).

- [ ] **Step 3: Commit**

```bash
git add config/multisite.uat.yml
git commit -m "$(cat <<'EOF'
DEV: Add UAT's multisite DB config (local Postgres, no secret)

Unlike config/multisite.yml (production, RDS-backed, must stay
secret-filled-at-deploy-time), UAT's local Postgres uses trust auth
over the Unix socket -- nothing secret to keep out of git -- so this
is committed directly with real, final content. containers/uat.yml's
after_code hook copies it over config/multisite.yml inside the UAT
image only.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `containers/uat.yml` — multisite container definition

**Files:**
- Modify: `containers/uat.yml` (full rewrite of the `env`/`hooks`/`run` sections)
- Reference (read, do not modify): `containers/app.yml` (source of the two initializers and the
  `patch-configure-ssl` step, copied verbatim/adapted)

**Interfaces:**
- Consumes: `config/multisite.uat.yml` (Task 1) — copied into place by the `after_code` hook.
- Produces: the container definition Task 3/4's deploy workflows upload as-is (no secrets are
  templated into this file beyond what already exists today — `<GITHUB_PAT>`,
  `<DISCOURSE_SMTP_USERNAME>`, `<DISCOURSE_SMTP_PASSWORD>`, `<UAT_DISCOURSE_S3_ACCESS_KEY_ID>`,
  `<UAT_DISCOURSE_S3_SECRET_ACCESS_KEY>`, `<UAT_VERSION>` placeholders, substituted by the
  workflows exactly as today).

- [ ] **Step 1: Update the top-of-file comment** to describe the new multisite topology (3
  hostnames, one container, local-but-multisite Postgres) instead of the current single-site
  description.

- [ ] **Step 2: Update `env:` block**
  - `UNICORN_WORKERS: 2` (was `1`).
  - `DISCOURSE_HOSTNAME: uat.navodians.com` (was `uat.nitians.in`).
  - Add `DISCOURSE_HOSTNAME_ALIASES: uat.nitians.in,uat.iitians.in`.
  - `DISCOURSE_SMTP_DOMAIN: uat.navodians.com` (was `uat.nitians.in`).
  - `DISCOURSE_SMTP_USER_NAME`/`DISCOURSE_SMTP_PASSWORD` placeholders stay as `<...>` tokens, but
    rename them to `<UAT_DISCOURSE_SMTP_USERNAME>`/`<UAT_DISCOURSE_SMTP_PASSWORD>` so Task 3/4's
    substitution map is unambiguous about which secret feeds them (see Global Constraints: these
    are new, UAT-dedicated secrets, replacing the shared-with-production ones).
  - `DISCOURSE_S3_BUCKET: uat-navodians-forum-uploads` (was `uat-nitians-forum-uploads` — this
    becomes the global/default bucket; `uat-nitians-forum-uploads` and the new
    `uat-iitians-forum-uploads` are set per-site via each seeded site's `s3_upload_bucket` setting,
    same production pattern — see Task 7).
  - Add `DISCOURSE_CDN_URL: "https://cdn.uat.navodians.com"`.
  - Add `DISCOURSE_S3_CDN_URL: ""` (same empty-override purpose as `app.yml` — see that file's
    comment — so the baked-in image value never shadows each site's own per-site `s3_cdn_url`).
  - Do **not** add `DISCOURSE_S3_BACKUP_BUCKET` or `DISCOURSE_BACKUP_LOCATION` (Global Constraints
    — no S3 backups for UAT).

- [ ] **Step 3: Update `hooks.after_code`** — replace the existing
  ```yaml
  - exec:
      cmd:
        - rm -f $home/config/multisite.yml
  ```
  with:
  ```yaml
  - exec:
      cmd:
        - cp $home/config/multisite.uat.yml $home/config/multisite.yml
  ```
  Update the comment above it to explain the new reasoning (UAT is now genuinely multisite; this
  file has no secret in it, unlike production's, so a plain copy is sufficient — see
  `config/multisite.uat.yml`).

- [ ] **Step 4: Add `hooks.after_db_migrate`** (new key, sibling to `after_code`/`before_yarn`):
  ```yaml
  after_db_migrate:
    - exec:
        cd: $home
        cmd:
          - su discourse -c 'bundle exec rake multisite:migrate'
  ```
  Remove the old comment that said "No after_db_migrate hook: UAT is single-site...".

- [ ] **Step 5: Add `hooks.after_postgres`** (new key) — resolves the spec's open risk. Creates
  the two extra logical databases idempotently, under the same `discourse` role, with the same
  extensions `templates/postgres.template.yml`'s own `create_db` script creates for the default
  database:
  ```yaml
  after_postgres:
    - exec:
        cmd:
          - |
            su postgres -c "createdb -O discourse uat_nitians" || true
            su postgres -c "createdb -O discourse uat_iitians" || true
            su postgres -c "psql uat_nitians -c 'create extension if not exists hstore;'"
            su postgres -c "psql uat_nitians -c 'create extension if not exists pg_trgm;'"
            su postgres -c "psql uat_nitians -c 'create extension if not exists vector;'"
            su postgres -c "psql uat_iitians -c 'create extension if not exists hstore;'"
            su postgres -c "psql uat_iitians -c 'create extension if not exists pg_trgm;'"
            su postgres -c "psql uat_iitians -c 'create extension if not exists vector;'"
  ```
  Add a comment above this block citing the mechanism: `templates/postgres.template.yml` (vendored
  from `discourse_docker`, not in this repo) only provisions one DB (`db_name`/`db_user` params,
  default `discourse`/`discourse`) via a `hook: postgres`-tagged step; `after_postgres` is pups'
  supported insertion point immediately after that step (see `discourse_docker/samples/data.yml`
  for the same pattern used to set a password). `uat_navodians` is the default DB created by that
  built-in step — set `db_name: uat_navodians` in `params:` (see Step 6) so the default database is
  already correctly named and this hook only needs to create the other two.

- [ ] **Step 6: Update `params:`** — add `db_name: uat_navodians` (so the default DB
  `postgres.template.yml` creates is already correctly named for the `navodians` site, instead of
  the generic `discourse` default). Leave `db_user` unset (defaults to `discourse`, matching
  `config/multisite.uat.yml`'s `username: discourse`).

- [ ] **Step 7: Add the two generic initializers to `run:`**, copied verbatim from
  `containers/app.yml`'s `run:` block (`per_site_cdn.rb` and `multisite_s3_cdn_fallback.rb` — copy
  their `file:` blocks exactly, including comments, since the spec requires byte-identical code to
  maximize the chance any bug in that logic shows up identically on UAT).

- [ ] **Step 8: Add the `patch-configure-ssl` step to `run:`**, copied verbatim from
  `containers/app.yml`'s `run:` block (the `file:` block that writes `/usr/local/bin/
  patch-configure-ssl` plus the `exec:` that runs it). Do **not** add the per-domain `www`→apex
  redirect block (`25-multisite.conf`) — add a one-line comment explaining why: UAT has no
  `www.uat.*` hostnames, so that block has nothing to ever match.

- [ ] **Step 9: Verify hook ordering** — read `pups`' hook-phase documentation (or inspect
  `discourse_docker`'s `launcher`/`pups` invocation order) to confirm `after_postgres` always runs
  before `after_db_migrate` within a single `launcher bootstrap uat` run (both are "after this
  named phase" hooks around different phases of the same bootstrap sequence — `postgres` is a
  `run:`-time hook from the postgres template itself, which executes before pups ever reaches
  Discourse's own `db_migrate` phase). Confirm this holds; if it doesn't, this step blocks the rest
  of the task until resolved.

- [ ] **Step 10: Lint**

Run: `bin/lint --fix containers/uat.yml`

- [ ] **Step 11: Dry-run verify idempotency and ordering** (requires AWS infra from Task 5 to not
  yet exist — this can run against a throwaway local/manual `launcher bootstrap uat` if a test
  instance is available, otherwise defer this specific sub-step to Task 9's live verification and
  note it there). At minimum: visually trace that `after_postgres`'s `createdb ... || true` pattern
  cannot fail the hook (and therefore the whole boot) on a database that already exists.

- [ ] **Step 12: Commit**

```bash
git add containers/uat.yml
git commit -m "$(cat <<'EOF'
DEV: Make UAT a true multisite install, mirroring production

UNICORN_WORKERS, DISCOURSE_HOSTNAME(_ALIASES), DISCOURSE_CDN_URL,
the per-site CDN/S3-fallback initializers, and the multisite nginx
SSL patch are now copied from containers/app.yml so UAT exercises the
exact same code paths production runs. The DB stays local Postgres
(not RDS) but is now 3 logical databases (uat_navodians/uat_nitians/
uat_iitians) under the same local discourse role, created via a new
after_postgres hook -- the supported discourse_docker insertion point
for extending postgres.template.yml's single-DB default. config/
multisite.uat.yml (committed, no secret) replaces the old rm -f hook.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `.github/workflows/deploy-uat.yml`

**Files:**
- Modify: `.github/workflows/deploy-uat.yml`

**Interfaces:**
- Consumes: new GitHub secrets `UAT_DISCOURSE_SMTP_USERNAME`/`UAT_DISCOURSE_SMTP_PASSWORD`
  (provisioned in Task 6); existing `UAT_DISCOURSE_S3_ACCESS_KEY_ID`/
  `UAT_DISCOURSE_S3_SECRET_ACCESS_KEY` (policy widened in Task 5, names unchanged).
- Produces: the exact same secret-substitution-map shape Task 4 must mirror.

- [ ] **Step 1: Update the "Write containers/uat.yml with secrets and upload it" step's `env:`
  block and Python placeholder map** — change:
  ```yaml
  DISCOURSE_SMTP_USERNAME: ${{ secrets.DISCOURSE_SMTP_USERNAME }}
  DISCOURSE_SMTP_PASSWORD: ${{ secrets.DISCOURSE_SMTP_PASSWORD }}
  ```
  to:
  ```yaml
  UAT_DISCOURSE_SMTP_USERNAME: ${{ secrets.UAT_DISCOURSE_SMTP_USERNAME }}
  UAT_DISCOURSE_SMTP_PASSWORD: ${{ secrets.UAT_DISCOURSE_SMTP_PASSWORD }}
  ```
  and update the Python placeholder list's two SMTP entries to
  `('<UAT_DISCOURSE_SMTP_USERNAME>', 'UAT_DISCOURSE_SMTP_USERNAME')` /
  `('<UAT_DISCOURSE_SMTP_PASSWORD>', 'UAT_DISCOURSE_SMTP_PASSWORD')` to match Task 2's renamed
  placeholders. Leave the S3 and `UAT_VERSION`/`GITHUB_PAT` entries unchanged (same secret names,
  just a wider IAM policy behind them).

- [ ] **Step 2: Replace the "Verify uat.nitians.in is up" step** with a loop over all 3 hostnames,
  mirroring `deploy.yml`'s existing multi-site verification loop:
  ```yaml
  - name: Verify all 3 UAT sites are up
    run: |
      for host in uat.navodians.com uat.nitians.in uat.iitians.in; do
        up=false
        for attempt in $(seq 1 60); do
          if [ "$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' https://$host/)" = "200" ]; then
            up=true
            break
          fi
          echo "Waiting for $host ($attempt/60)..."; sleep 5
        done
        if [ "$up" != true ]; then
          echo "$host did not come up in time"
          ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -i ~/.ssh/uat_key ubuntu@uat.nitians.in 'sudo docker logs --tail 200 uat'
          exit 1
        fi
        echo "$host is up"
      done
  ```
  (SSH diagnostics on failure still target `uat.nitians.in` since all 3 hostnames resolve to the
  same instance/container — this is not a per-host SSH target, just the one log source.)

- [ ] **Step 3: Update the rollback step's post-rollback verification loop** (the block starting
  `up=false` under "Roll back to last known-good image on failure") the same way — loop over all 3
  hostnames instead of checking only `uat.nitians.in`.

- [ ] **Step 4: Lint**

Run: `bin/lint --fix .github/workflows/deploy-uat.yml`

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/deploy-uat.yml
git commit -m "$(cat <<'EOF'
DEV: deploy-uat.yml: dedicated SES creds, verify all 3 UAT hostnames

UAT previously reused production's DISCOURSE_SMTP_USERNAME/PASSWORD
secrets -- now uses its own UAT_DISCOURSE_SMTP_USERNAME/PASSWORD,
completing infra isolation from production. The post-deploy and
post-rollback verification steps now check all 3 uat.* hostnames
instead of only uat.nitians.in, matching deploy.yml's existing
multi-site pattern.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `.github/workflows/uat-control.yml`

**Files:**
- Modify: `.github/workflows/uat-control.yml`

**Interfaces:**
- Consumes: same as Task 3 (`UAT_DISCOURSE_SMTP_USERNAME`/`UAT_DISCOURSE_SMTP_PASSWORD`).
- Produces: nothing consumed elsewhere — this task exists solely to keep this workflow from
  drifting out of sync with Task 3 (see Review Focus).

- [ ] **Step 1: Apply the identical `env:`/Python-placeholder-map change from Task 3 Step 1** to
  `uat-control.yml`'s own "Write containers/uat.yml with secrets and upload it" step (same
  env/placeholder names).

- [ ] **Step 2: Apply the identical multi-hostname verification loop from Task 3 Step 2** to
  `uat-control.yml`'s own "Verify uat.nitians.in is up" step, renaming it "Verify all 3 UAT sites
  are up" to match.

- [ ] **Step 3: Diff the two workflows' changed blocks against each other** to confirm byte-for-
  byte parity in the secret names and verification loop (this is the test for this task — there is
  no separate executable test, since this is a GitHub Actions workflow; parity with the
  already-reasoned-through Task 3 is what makes it correct).

Run: `diff <(sed -n '/Write containers\/uat.yml/,/^$/p' .github/workflows/deploy-uat.yml) <(sed -n '/Write containers\/uat.yml/,/^$/p' .github/workflows/uat-control.yml)`
Expected: only the step name and any genuinely workflow-specific lines differ (e.g.
`uat-control.yml` doesn't have `UAT_VERSION` substitution from a `ver` step output in quite the
same place if its version-resolution step differs) — the secret env var names and placeholder map
must be identical.

- [ ] **Step 4: Lint**

Run: `bin/lint --fix .github/workflows/uat-control.yml`

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/uat-control.yml
git commit -m "$(cat <<'EOF'
DEV: uat-control.yml: mirror deploy-uat.yml's SES/multi-host changes

uat-control.yml duplicates deploy-uat.yml's secret-substitution and
verification blocks almost byte-for-byte; keep it in sync so the
manual start/stop workflow doesn't silently break while the automated
deploy workflow works.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: AWS infrastructure provisioning

**Files:** none (AWS resources only; no repo files change in this task).

**Interfaces:**
- Produces: 3 S3 buckets, 3 CloudFront distributions + ACM certs, 2 new Route 53 A records + 3 CDN
  CNAMEs, 1 widened IAM policy, 1 new SES domain identity + DKIM records — all consumed by Task 3/4
  (already written against the final names) and Task 7/9 (seeding and live verification).

**This entire task is gated: get explicit user confirmation before each mutating sub-step below.**
Read-only discovery calls (already run during planning, reusable): `aws route53
list-hosted-zones`, `aws s3api list-buckets`, `aws cloudfront list-distributions`, `aws sesv2
list-email-identities` — all `--profile personal`.

- [ ] **Step 1: Load the `aws-core` plugin skills** — invoke `aws-core:aws-storage` (S3 bucket +
  CloudFront/OAC guidance), `aws-core:aws-networking` (Route 53 + CloudFront DNS/cert guidance),
  and `aws-core:aws-security` (IAM least-privilege policy guidance) via the Skill tool before
  writing any `aws` CLI mutation command, so bucket policies use OAC (not legacy OAI) and the IAM
  policy is scoped to exactly the 3 UAT bucket ARNs.

- [ ] **Step 2 (CONFIRM FIRST): Create 2 new S3 buckets** — `uat-navodians-forum-uploads`,
  `uat-iitians-forum-uploads` (region `ap-south-1`), matching whatever bucket-policy/public-access
  posture the existing `uat-nitians-forum-uploads` bucket already uses (inspect it first with
  `aws s3api get-bucket-policy`/`get-public-access-block` — read-only — before creating the new
  two, so all 3 end up configured identically).

- [ ] **Step 3 (CONFIRM FIRST): Create 2 new CloudFront distributions** (`cdn.uat.navodians.com`,
  `cdn.uat.iitians.in`; `cdn.uat.nitians.in` is also new as UAT has never had a CDN before — so
  this is actually 3 new distributions, not 2), each with its own origin (its matching UAT
  bucket), Origin Access Control (not legacy OAI, per `aws-storage` guidance), and its own ACM
  cert (ACM certs for CloudFront must be requested in `us-east-1` regardless of the bucket's
  region — per `aws-networking` guidance).

- [ ] **Step 4 (CONFIRM FIRST): Add DNS records** in the 3 zones confirmed during planning
  (`navodians.com` → `Z01839133PSJPBM657V7N`, `nitians.in` → `Z0746140Z037GXIG5GET`, `iitians.in`
  → `Z09039812NKNJUGOJXEOB`): 2 new A records (`uat.navodians.com`, `uat.iitians.in` → the existing
  `uat-nitians-ip` static IP; `uat.nitians.in`'s A record already exists) and 3 CDN CNAMEs
  (`cdn.uat.navodians.com`, `cdn.uat.nitians.in`, `cdn.uat.iitians.in` → each distribution's
  `*.cloudfront.net` domain from Step 3), plus whatever ACM DNS-validation CNAME records Step 3's
  cert requests need.

- [ ] **Step 5 (CONFIRM FIRST): Create the new SES domain identity** `uat.navodians.com` (region
  `ap-south-1`) and add its DKIM/SPF DNS records (in the `navodians.com` zone,
  `Z01839133PSJPBM657V7N`) once SES returns them.

- [ ] **Step 6 (CONFIRM FIRST): Widen the existing UAT S3 IAM policy** to cover all 3 new bucket
  ARNs (`arn:aws:s3:::uat-navodians-forum-uploads*`, `arn:aws:s3:::uat-nitians-forum-uploads*`,
  `arn:aws:s3:::uat-iitians-forum-uploads*`), reusing the existing IAM user/access key (no new S3
  secret — see Global Constraints).

- [ ] **Step 7: Verify** (read-only, after confirmation + execution of Steps 2–6):
  `aws s3api list-buckets`, `aws cloudfront list-distributions`, `aws route53
  list-resource-record-sets --hosted-zone-id <each zone>`, `aws sesv2 get-email-identity
  --email-identity uat.navodians.com` all show the expected new resources.

- [ ] **Step 8: Record the final resource IDs** (bucket names, distribution IDs/domains, SES
  identity ARN) for Task 8's `docs/UAT.md` rewrite — no commit in this task; this is AWS-side only.

---

### Task 6: GitHub Actions secrets

**Files:** none (GitHub repo secrets only).

**Interfaces:**
- Consumes: SES SMTP credentials generated against Task 5 Step 5's new identity.
- Produces: `UAT_DISCOURSE_SMTP_USERNAME`, `UAT_DISCOURSE_SMTP_PASSWORD` — consumed by Task 3/4's
  already-written substitution maps.

**This task is gated: get explicit user confirmation before adding any secret.**

- [ ] **Step 1 (CONFIRM FIRST): Generate SES SMTP credentials** for the `uat.navodians.com`
  identity (via the SES console's "Create SMTP credentials" IAM-user-generation flow, or
  equivalent `aws iam`/`aws ses` calls per `aws-security` guidance).

- [ ] **Step 2 (CONFIRM FIRST): Add GitHub repo secrets** `UAT_DISCOURSE_SMTP_USERNAME` /
  `UAT_DISCOURSE_SMTP_PASSWORD` via `gh secret set UAT_DISCOURSE_SMTP_USERNAME` /
  `gh secret set UAT_DISCOURSE_SMTP_PASSWORD`.

- [ ] **Step 3: Verify**

Run: `gh secret list | grep UAT_DISCOURSE_SMTP`
Expected: both secrets listed (values are never shown, only names/update times).

---

### Task 7: Seed + PII-scrub `navodians_forum` and `iitians_forum` into UAT

**Files:** none (operates against production and the live UAT instance over SSH — this
reproduces the same ad hoc, uncommitted process already used for `nitians_forum`, per
`docs/UAT.md`'s existing "see git history for the exact scrub script" note; it is not re-committed
as a repo script here, consistent with how it was done before).

**Interfaces:**
- Consumes: Task 5's 3 S3 buckets + CDN domains (to repoint `s3_upload_bucket`/`s3_cdn_url`), Task
  2's `uat_navodians`/`uat_iitians` databases (created by the `after_postgres` hook on first UAT
  boot after Task 2 ships — this task's dumps must run *after* a UAT deploy has booted at least
  once with the new `containers/uat.yml`, so the target databases already exist).

**This task is gated: get explicit user confirmation before running `pg_dump` against
production**, even though it is read-only and non-locking, per the standing instruction to confirm
before touching production.

- [ ] **Step 1 (CONFIRM FIRST): `pg_dump` `navodians_forum`** from inside production's `app`
  container over SSH, the same consistent-snapshot, non-locking method already used for
  `nitians_forum` (see `docs/UAT.md`'s "Database" section for the exact prior process/column list).

- [ ] **Step 2: Restore into `uat_navodians`** on the UAT instance, owned by `discourse` directly
  (not `postgres` + reassign — see commit `5a00bdd5f52`'s documented reasoning: `REASSIGN OWNED BY`
  fails on objects Postgres itself requires; creating with `-O discourse` and restoring as the
  `discourse` OS/role via peer auth avoids the problem entirely).

- [ ] **Step 3: Run the PII scrub** against `uat_navodians` only (never against production),
  applying the exact same rules `docs/UAT.md`'s current "Database" section documents for
  `nitians_forum`: `user_emails`/`email_tokens`/`email_change_requests` synthesized,
  `email_login_codes`/`email_logs`/`incoming_emails`/`screened_emails` deleted, IP columns nulled
  on `users`/`incoming_links`/`user_histories`, `user_ip_address_histories` deleted,
  `user_auth_tokens`/`user_auth_token_logs`/`user_api_keys`/`user_second_factors`/
  `user_security_keys` deleted, `user_passwords` randomized, private-message post/topic content
  redacted, DM-only chat content redacted.

- [ ] **Step 4: Repoint `navodians` site settings** in `uat_navodians`: `s3_upload_bucket` →
  `uat-navodians-forum-uploads`, `s3_cdn_url` → `https://cdn.uat.navodians.com` (Task 5's values).

- [ ] **Step 5: Repeat Steps 1–4 for `iitians_forum` → `uat_iitians`**, repointing to
  `uat-iitians-forum-uploads` / `https://cdn.uat.iitians.in`.

- [ ] **Step 6: Repoint the already-seeded `uat_nitians`'s site settings** (it currently has no
  per-site bucket override since it was the single default bucket before this change) to
  `uat-nitians-forum-uploads` / `https://cdn.uat.nitians.in` — this DB was already seeded/scrubbed
  previously, so only the repointing is new for this site.

- [ ] **Step 7: Verify per-site routing before considering this task done** (the Review Focus item
  for this task) — for each of the 3 databases, query:
  `SELECT value FROM site_settings WHERE name IN ('s3_upload_bucket', 's3_cdn_url');`
  and confirm each database's values match only its own bucket/CDN, never another site's or
  production's.

---

### Task 8: Rewrite `docs/UAT.md`

**Files:**
- Modify: `docs/UAT.md`

**Interfaces:**
- Consumes: Task 5's final resource IDs (bucket names, distribution domains, SES identity, zone
  IDs — all already known/decided in this plan's Global Constraints, so this task does not block
  on Task 5 actually having run; it documents the target state).

- [ ] **Step 1: Update the title and intro** — "UAT Environment — uat.navodians.com,
  uat.nitians.in, uat.iitians.in" (or similar), describing it as a 3-site multisite preview
  mirroring production's topology, local-Postgres-only exception noted explicitly.

- [ ] **Step 2: Update "How it works"** — note `containers/uat.yml` is now `app.yml`'s multisite
  counterpart (same hooks/initializers/nginx patch, different DB backend), not its single-site
  counterpart.

- [ ] **Step 3: Rewrite "Database: local PostgreSQL..." section** — describe 3 logical databases
  (`uat_navodians`/`uat_nitians`/`uat_iitians`) under one local `discourse` role, the
  `after_postgres` hook mechanism that creates the 2 extra ones (cite `containers/uat.yml`,
  explain *why* — `postgres.template.yml`'s single-DB default), and that `multisite:migrate` now
  genuinely runs (unlike today's single-site `db:migrate`-only note, which should be removed).

- [ ] **Step 4: Rewrite the seed/scrub section** to describe the process for all 3 sites (reference
  Task 7's steps), including the new `s3_upload_bucket`/`s3_cdn_url` repointing step per site.

- [ ] **Step 5: Update "One-time setup"** — add the 2 new DNS A records + 3 CDN CNAMEs (with the
  confirmed zone IDs from Global Constraints), the 3 S3 buckets, the 3 CloudFront distributions +
  ACM certs, and the new SES identity + DKIM setup. Update the GitHub secrets list: add
  `UAT_DISCOURSE_SMTP_USERNAME`/`UAT_DISCOURSE_SMTP_PASSWORD`, note
  `UAT_DISCOURSE_S3_ACCESS_KEY_ID`/`SECRET_ACCESS_KEY` now cover 3 buckets under one IAM user.

- [ ] **Step 6: Lint**

Run: `bin/lint --fix docs/UAT.md`

- [ ] **Step 7: Commit**

```bash
git add docs/UAT.md
git commit -m "$(cat <<'EOF'
DOCS: Rewrite docs/UAT.md for the 3-site multisite UAT architecture

Covers the 3 logical local databases, the after_postgres hook that
creates them, the per-site seed/scrub + S3/CDN repointing process
repeated for all 3 sites, and the expanded one-time AWS setup (2 new
DNS records, 3 CDN CNAMEs, 3 S3 buckets, 3 CloudFront distributions,
new dedicated SES identity).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: End-to-end verification

**Files:** none.

**Interfaces:**
- Consumes: everything from Tasks 1–8, fully merged and deployed.

- [ ] **Step 1: Trigger a manual deploy**

Run: `gh workflow run deploy-uat.yml --ref master`

- [ ] **Step 2: Confirm all 3 hostnames return 200** and check the deploy logs for
  `patch-configure-ssl`'s own printed message (`configure-ssl patched: single-site redirect
  removed` or `configure-ssl: redirect block not found (already patched?)` — the latter on a
  reused/already-patched image is fine, but if it ever prints neither, that's the Review Focus
  failure mode to catch).

Run: `for host in uat.navodians.com uat.nitians.in uat.iitians.in; do curl -sk -o /dev/null -w "$host: %{http_code}\n" https://$host/; done`
Expected: all three print `200`.

- [ ] **Step 3: Confirm `multisite:migrate` ran cleanly** by checking the deploy workflow's logs
  (the `after_db_migrate` hook's output) for no migration errors across all 3 databases.

- [ ] **Step 4: Confirm each site's admin panel shows its own seeded (scrubbed) data** — log into
  `https://uat.navodians.com/admin`, `https://uat.nitians.in/admin`, `https://uat.iitians.in/admin`
  and spot-check each shows that site's own topics/users, not another site's or empty data.

- [ ] **Step 5: Confirm per-site CDN/S3 routing** — upload a test image on each of the 3 UAT sites
  and check the resulting URL is served from that site's own `cdn.uat.*` domain (via browser
  devtools or `curl -I` on the image URL), never another site's.

- [ ] **Step 6: Confirm SES** — trigger a test notification email from each of the 3 UAT sites
  (e.g. password reset) and confirm it sends successfully under the new `uat.navodians.com`
  identity (check `AiApiAuditLog`-equivalent SES sending logs or the email headers' `Return-Path`/
  `DKIM-Signature` domain — should never be `navodians.com`/`nitians.in`/`iitians.in` production's
  identities).

- [ ] **Step 7: Report completion** to the user with the links/results from Steps 2–6.
