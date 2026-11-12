# UAT → production parity (multisite), excluding DB backend

## Context

Two serial production regressions (push notifications, root-caused and fixed in PRs #54/#55)
shipped through `deploy-uat.yml`'s PR preview and `master` preview without being caught, even
though UAT previews every push to `master` and every PR. The underlying code bugs were generic
Ruby regressions (methods/constants silently reverted by a stale merge) — not multisite-specific
— so they would have reproduced on UAT too, *if* the broken flow had actually been exercised
there. Today's UAT is also missing several pieces of production's real configuration (custom
`run:` hooks, worker count, CDN env vars) that exist specifically to catch classes of bugs that
only show up under production's actual boot/runtime configuration (e.g. the 2026-11-04 stale
Docker base-image outage was caught by UAT's from-scratch instance precisely because UAT always
builds with zero Docker cache — the inverse of this effort: production should look like UAT
there, and UAT should look like production everywhere else).

Goal: make UAT structurally and behaviorally identical to production — same multisite topology,
same hostnames-per-site pattern, same custom hooks/initializers/nginx patches, same per-site
S3/CDN routing — so that exercising any flow against UAT exercises the exact same code paths
production runs. The one deliberate, explicit exception is the database backend: UAT keeps its
local PostgreSQL container (not RDS), per explicit instruction, to avoid ever sharing CPU/IOPS/
connections with production's shared `db.t4g.micro` RDS instance. Within that constraint, UAT's
database becomes genuinely multisite (3 logical databases, one per site) rather than today's
single `discourse` database, so multisite-specific code paths (`multisite:migrate`, per-site site
settings, per-site CDN/bucket routing) are exercised too.

A second, explicit requirement from this round of brainstorming: UAT must not share *any* other
production infrastructure either (previously, SMTP/SES identity was shared — this changes too).
Every other piece of infra (S3 buckets, CDN, SES identity, SSL certs) gets its own UAT-dedicated
resource.

## Non-goals

- This does not change how PRs get *tested* (no new automated e2e push-notification test is
  added here) — it only ensures that *if* someone manually or automatically exercises a flow
  against UAT, the result reflects production's actual code paths and config. Closing the "nobody
  tested push notifications against UAT" gap is a process change, not an infra change, and is out
  of scope for this spec.
- No change to `bin/rspec`'s pre-existing, unrelated RDS-networking problem
  (`project_tests_yml_hits_production_rds` in memory) — orthogonal to this effort.
- No mobile-app changes to let a test device target `uat.*` hostnames — out of scope; noted as a
  prerequisite for anyone who wants to manually verify push notifications against UAT, not
  something this infra change does automatically.

## Decisions made during brainstorming

1. **UAT becomes true multisite** (not single-site): `uat.navodians.com`, `uat.nitians.in`
   (existing), `uat.iitians.in`, served from the same single Lightsail instance/static IP, exactly
   mirroring production's one-container-three-hostnames topology.
2. **Database stays local Postgres** (no RDS), but becomes 3 logical databases inside the same
   local Postgres container instead of 1, so `multisite:migrate` and per-site settings are real.
3. **Full infra isolation from production**: separate S3 buckets (3, one per site), separate
   CloudFront distributions/CDN domains (3, one per site), separate SES sending identity/domain
   (not shared with production's), separate SSL certs. Compute/disk/key-pair/snapshot AWS
   resource *names* are reused as-is (`uat-nitians`, `uat-nitians-key`, `uat-nitians-db-disk`,
   `uat-nitians-base-snapshot`) since renaming them is pure churn with no functional benefit — they
   were already UAT-dedicated, never shared with production.
4. **All 3 UAT databases get seeded from production** via the same one-time `pg_dump` + PII-scrub
   process already used for `nitians_forum` (read-only against production, no locking), run once
   more each for `navodians_forum` and `iitians_forum`. The seed/scrub step is additionally
   extended to repoint each site's `s3_upload_bucket`/`s3_cdn_url` site settings at the new
   UAT-dedicated bucket/CDN instead of leaving them pointed at production's (otherwise UAT would
   silently read uploads from production's live bucket) — same already-accepted limitation as
   today (pre-scrub historical upload *files* themselves are not copied, so old inline images
   will 404 on UAT; this is unchanged from today's single-site UAT and not something this effort
   fixes).
5. **No S3-backed backups for UAT** (production's `DISCOURSE_BACKUP_LOCATION: s3` is not mirrored)
   — backups don't help catch code regressions and add AWS spend/complexity with no parity
   benefit for this goal.

## Architecture

### Hostnames / DNS / SSL

Single Lightsail instance, single static IP (reusing `uat-nitians-ip`), one `uat` container,
`DISCOURSE_HOSTNAME: uat.navodians.com`, `DISCOURSE_HOSTNAME_ALIASES: uat.nitians.in,uat.iitians.in`
(no `www.` aliases — not needed for a test environment). Two new Route 53 A records
(`uat.navodians.com`, `uat.iitians.in` → the existing static IP) in whichever zones actually host
`navodians.com`/`iitians.in` (verify delegation the same way `docs/UAT.md`'s existing one-time
setup notes already flag for `nitians.in`). Let's Encrypt issues one multi-SAN cert covering all
three UAT hostnames, same mechanism already in use.

### Database (local Postgres, multisite)

Same `templates/postgres.template.yml` container on the same persistent Lightsail disk
(`uat-nitians-db-disk`, mounted at `/var/discourse/shared/uat`) — no RDS, no architecture change to
the DB *container* itself. Three logical databases live inside that one local Postgres server:
`uat_navodians`, `uat_nitians`, `uat_iitians`, all owned by the same local `discourse` role.

**Known open technical risk, to resolve during implementation (not a design blocker):**
`postgres.template.yml` is vendored from `discourse_docker` at deploy time (not in this repo) and
by default provisions exactly one local database. Multisite-over-local-Postgres needs an extra
hook (likely an `after_postgres`/`after_bootstrap`-style `exec` in `uat.yml`, run idempotently on
every container start) to `createdb` the two additional logical databases under the same local
role the first time they don't exist. The exact hook point will be confirmed by reading the actual
`postgres.template.yml` from the cloned `discourse_docker` repo during implementation.

UAT's multisite config points each site at the local socket/role instead of RDS. Unlike
production's `config/multisite.yml` (which must stay secret-filled-at-deploy-time because it
carries a real RDS password), **UAT's version carries no secret at all** — local Postgres here
uses trust auth over the Unix socket, so there is no password to keep out of git. It is therefore
committed directly to the repo as `config/multisite.uat.yml`, with real, final content (no
placeholders, nothing substituted at deploy time):

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

(Exact `username`/auth mechanism to be confirmed against what `postgres.template.yml` actually
provisions — the local container's existing single-DB setup already uses *some* local role/trust
config; this file must match it exactly, substituting only `database:`/`host_names:` per site.)

`config/multisite.yml` itself (production's, with its RDS host/password placeholder) is untouched
— `config/multisite.uat.yml` lives alongside it as a separate, plain, always-accurate file. An
`after_code` hook in `containers/uat.yml` copies it over at build time: `cp
$home/config/multisite.uat.yml $home/config/multisite.yml` (replacing the production placeholder
file *inside that one UAT build only* — the repo's own `config/multisite.yml` is never modified).
This replaces today's `rm -f $home/config/multisite.yml` hook, and needs no new deploy-time
secret-writing step, no new GitHub secret, and no bind mount — simpler than the original
bind-mount approach this section previously described, since there's genuinely nothing secret to
keep out of git.

### `containers/uat.yml` changes

- Replace the `rm -f $home/config/multisite.yml` `after_code` hook with
  `cp $home/config/multisite.uat.yml $home/config/multisite.yml` (see "Database" above — no
  secrets involved, so this is a plain file copy, not a secrets-filled bind mount).
- Add `after_db_migrate: su discourse -c 'bundle exec rake multisite:migrate'` (verbatim from
  `app.yml`), since UAT is now genuinely multisite.
- `UNICORN_WORKERS: 2` (was 1) — matches production's worker count.
- `DISCOURSE_HOSTNAME`/`DISCOURSE_HOSTNAME_ALIASES` per the 3-site pattern above.
- Add `DISCOURSE_CDN_URL: "https://cdn.uat.navodians.com"` (global compiled-asset CDN, mirroring
  production's pattern of a single global CDN for compiled JS/CSS regardless of site).
- `DISCOURSE_S3_BUCKET` becomes the UAT-dedicated global/default bucket
  (`uat-navodians-forum-uploads`), with per-site buckets (`uat-nitians-forum-uploads`,
  `uat-iitians-forum-uploads`) set via each site's own `s3_upload_bucket` site setting in its
  seeded DB (same production pattern).
- Add the two generic initializers verbatim from `app.yml`'s `run:` block: `per_site_cdn.rb` and
  `multisite_s3_cdn_fallback.rb` — these are site-agnostic Ruby, so copying them exactly maximizes
  the chance that a bug in that logic (the same class of silent-monkeypatch-drop that caused the
  original regression) shows up in UAT the same way it would in production.
- Add the `patch-configure-ssl` step and the per-domain `www`→apex nginx redirect block, adapted
  to UAT's hostnames (even though UAT doesn't use `www.` aliases, keeping this step is what
  exercises the exact same "default single-site nginx redirect breaks a multisite install unless
  patched" code path production depends on — the win here is exercising the *patch*, not the
  redirect targets, so the block can be a reduced/no-op variant for UAT if there's nothing to
  redirect; confirmed during implementation whether a no-op block is worth keeping for coverage or
  should simply be omitted since there's no `www.uat.*` hostname to protect).

### AWS infrastructure

| Resource | Today | After |
|---|---|---|
| S3 buckets | 1 (`uat-nitians-forum-uploads`) | 3: `uat-navodians-forum-uploads`, `uat-nitians-forum-uploads` (kept), `uat-iitians-forum-uploads` |
| CDN | none | 3 CloudFront distributions: `cdn.uat.navodians.com` / `cdn.uat.nitians.in` / `cdn.uat.iitians.in`, each fronting its own bucket, each with its own ACM cert + DNS CNAME |
| SES / SMTP | shared production identity | dedicated UAT sending identity/domain, own DKIM/SPF records, own SMTP IAM creds (regional SES *endpoint* URL itself is unchanged — only the identity/credentials are UAT-dedicated) |
| Compute/disk/key/snapshot | `uat-nitians*` | unchanged names, reused as-is |
| DNS | 1 A record (`uat.nitians.in`) | 3 A records + 3 CDN CNAMEs |

Implementation of these AWS resources (bucket policies, IAM scoping, CloudFront origin/cert setup,
SES domain verification) should follow the `aws-core` plugin's `aws-storage`, `aws-networking`,
and `aws-security` skills for current best-practice configuration (least-privilege bucket
policies, OAC instead of legacy OAI for CloudFront→S3, etc.) rather than hand-rolling from first
principles.

### `.github/workflows/deploy-uat.yml` changes

- No new secrets-writing step is needed for multisite config — `config/multisite.uat.yml` is
  committed, plain, and already correct in every checkout; the `after_code` hook in
  `containers/uat.yml` handles putting it in place (see above).
- New GitHub secrets: per-bucket S3 credentials (or one IAM user scoped across all 3 UAT buckets —
  decide during implementation per least-privilege guidance from `aws-security`), new SES SMTP
  username/password.
- "Verify uat.nitians.in is up" step becomes "Verify all 3 UAT sites are up" (loop over the 3
  hostnames), mirroring `deploy.yml`'s existing multi-site verification loop.
- Rollback step's nginx-reload-after-rollback logic is unchanged in shape but now actually matters
  for 3 hostnames instead of 1.

### `docs/UAT.md` changes

Rewritten to describe the 3-site multisite architecture: updated "How it works", a new "Database"
section describing 3 logical local databases instead of 1, an updated "One-time setup" section
covering the 2 new DNS records, 3 S3 buckets, 3 CloudFront distributions + certs, and the new SES
identity, and an updated seed/scrub section describing the process repeated for all 3 sites plus
the new `s3_upload_bucket`/`s3_cdn_url` repointing step.

## Testing / verification

- After implementation: trigger `deploy-uat.yml` manually (`gh workflow run deploy-uat.yml --ref
  master`) and confirm all 3 `uat.*` hostnames return `200`, `multisite:migrate` ran cleanly in the
  deploy logs, and each site's admin panel shows its own seeded (scrubbed) data.
- Confirm the per-site CDN/S3 routing actually works by uploading a test image on each of the 3
  UAT sites and checking it's served from that site's own `cdn.uat.*` domain, not another site's.
- Confirm SES: send a test notification email from each UAT site, verify it sends under the new
  dedicated identity (not production's).
- This spec does not include retesting the push-notification fix itself — that was already
  verified live against production in the prior session. Once UAT is multisite and parity-complete,
  it becomes the right place to re-run that same `test_push2.rb`-style verification *before* future
  deploys, but wiring that into an automated pre-deploy gate is future work, not part of this spec.
