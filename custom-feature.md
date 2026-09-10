# Custom Features — Phantix / nvs-forum

Documentation of the features shipped on `master` ahead of upstream `main`:
requirements, implementation details, and known edge cases. These originated
as 8 separate commits (listed below by title for reference), but this doc
identifies each feature by name and by the files it touches rather than by
commit hash, since hashes don't survive a rebase or squash — if these commits
get squashed into one, the titles below double as a ready-made multi-line
squash commit message.

```
feat : batch moderation
feat : auth custom field validation fix
feat : Calendar College Filter
feat : Enhaced onboarding(registeration, invitation and login) process
feat : Mobile Notification Integration
Allow moderators to bulk invite users via CSV
feat : Trigger production deployment and local changes
Phantix Deployment
```

---

## 1. Batch Moderator Role + Cohort-Scoped Admin Users List

*(originally: `feat : batch moderation`; substantially redesigned since —
see "v2 redesign" below. The `/g`-page-based grant/revoke workflow and the
`/u` cohort filters described in the original commit still exist as UI
surfaces, but are no longer how Batch Moderator status is granted/managed —
that moved to the admin Users list, described here.)*

### Requirement

Admins on nitians.in, iitians.in and navodians.com wanted to delegate a narrow
moderation power — suspend, silence, or report a user — to trusted members of
that user's own cohort, **without** making them full site moderators. The
cohort key itself needed to account for a Student/Staff distinction discovered
in production data (nitians_forum's `"I am"` UserField:
`"Alumni/Student"` vs `"Dean/Professor/Staff"`) — a staff member's cohort is
their institution alone, not institution+Batch+Branch. Management moved off
the general `/g` groups directory (which the auto-generated `bm-*` cohort
groups were cluttering) onto a purpose-built view: Batch Moderators can browse
their own cohort — with a restricted, directory-like field set — on the admin
Users list (`/admin/users/list/active`), and admins see everyone there
(including Batch Moderators, flagged by icon) with full cohort filtering
(College/Batch/Branch or Vidyalaya/Batch dropdowns, a "Staff Only" toggle,
ported from `/u`) plus Grant/Revoke Batch Moderator buttons on the admin user
detail page, mirroring the existing Grant/Revoke Moderation UI. Granting/
revoking is admin-only. A cohort or status change needed to notify admins,
site moderators, and the cohort's current Batch Moderators every time.

### Implementation

**Cohort → Group auto-provisioning** (`lib/batch_moderation/group_sync.rb`):
- `GroupSync.sync(user, notify: true)` runs on `user_created`/`user_updated`
  (`config/initializers/301-batch-moderation.rb`). The cohort key always
  requires an **institution** value (College or Vidyalaya — first `UserField`
  found among `SiteSetting.batch_moderation_institution_field_names`, pipe-
  delimited, default `"College|Vidyalaya"`, same graceful-degradation pattern
  as before: each site is a separate database, so which field exists varies
  per site).
- Whether Batch/Branch also join the key depends on a **Student vs Staff**
  distinction: `staff_type?(user)` checks the site's member-type field
  (`SiteSetting.batch_moderation_member_type_field_name`, default `"I am"`)
  against `SiteSetting.batch_moderation_staff_type_values` (list, default
  `"Dean/Professor/Staff"`). Student-type members' keys also include Batch
  (`SiteSetting.batch_moderation_batch_field_name`, default `"Batch"`, still
  required) plus any of `SiteSetting.batch_moderation_secondary_field_names`
  (list, default `"Branch"` — narrowed from the original single-field
  `"Branch|Vidyalaya"` now that Vidyalaya lives in the institution setting;
  unlike the institution/type fields, *all* configured secondary fields that
  exist apply at once, not just the first found). Staff-type members' keys
  drop Batch/Branch entirely — one group per institution, not per
  institution+department. A site with no member-type field configured (still
  `iitians_forum`/`navodians_forum` as of this writing) treats everyone as
  Student, unchanged from the original behavior.
- Finds-or-creates a deterministically-named `Group` for that key
  (`bm-<sha1 prefix of the ordered component values>`), flagged via
  `group.custom_fields["batch_moderation_group"] = true`; `full_name` is a
  human-readable `" · "`-joined string (e.g. `"NIT Trichy · 2024 · CSE"`,
  or `"NIT Trichy · Staff"` for a staff cohort — the explicit suffix keeps the
  two group "shapes" visually distinguishable in any listing). Adds the user,
  removes them from any stale batch group if their fields changed — an owner
  who changes Batch/Branch/College loses Batch Moderator status for the old
  cohort immediately and is evaluated fresh against the new one, satisfying
  "changing cohort resets Batch Moderator status" with no separate logic.
- New groups: `automatic: false`, `logged_on_users` visibility, non-
  mentionable/non-messageable.
- `auto_promote_if_understaffed`: if a group has fewer owners than
  `SiteSetting.batch_moderation_auto_promote_count` (default **10**), the
  newly synced member is auto-promoted to owner. Owners of a batch group ARE
  the batch moderators for that cohort.
- `batch_moderator_user_ids(user_ids)` / `batch_group_for(user)` /
  `owned_batch_groups(user)`: batched/singular lookups shared by the directory
  serializer, the admin users list, the grant/revoke actions, and
  `StaffOrBatchModeratorConstraint`. `owned_batch_groups` is the single point
  of truth for the `enable_batch_moderation` kill switch — it (and therefore
  everything built on it) returns empty the instant the setting is off.

**Permission checks** (`lib/batch_moderation/moderator.rb`, unchanged):
- `can_moderate?(actor, target)` — true iff `actor != target`, they share an
  owned batch group, `target` isn't itself an owner of that group (peer owners
  can't moderate each other), and target isn't `staff?`.
- `can_report?(actor, target)` — same sharing check but *without* the
  peer-owner exclusion (you can still report a co-owner to real staff).

**Wiring into core Guardian, without touching core files directly**
(`lib/batch_moderation/guardian_extension.rb`, prepended onto `Guardian` in the
initializer):
```ruby
def can_suspend?(user)      = super || Moderator.can_moderate?(self.user, user)
def can_deactivate?(user)   = can_suspend?(user)
def can_silence_user?(user) = super || Moderator.can_moderate?(self.user, user)
def can_edit_group?(group)  = GroupSync.batch_group?(group) ? false : super
def can_grant_batch_moderator?(user) = can_administer?(user) &&
  GroupSync.batch_group_for(user).present? && !GroupSync.owned_batch_groups(user).exists?
def can_revoke_batch_moderator?(user) = can_administer?(user) &&
  GroupSync.owned_batch_groups(user).exists?
```
`can_edit_group?` now **unconditionally** denies membership edits on batch
groups, for anyone — admins included, not just non-staff. This is a
deliberate v2 tightening (see below): the original version allowed
`can_admin_group?`-holders (admins, and moderators when
`moderators_manage_groups` is on) through, which left the stock `/g` group
page's own Manage → Membership owner-toggle as a second, unnotified,
non-admin-restricted way to grant/revoke Batch Moderator status. Restricting
it fully means `Admin::UsersController#grant_batch_moderator`/
`#revoke_batch_moderator` (below) are the *sole* path by which a batch group's
ownership — and therefore Batch Moderator status — can change; `GroupSync.sync`
remains the sole path by which plain *membership* of these groups changes.
`can_grant_batch_moderator?`/`can_revoke_batch_moderator?` are deliberately
gated on `can_administer?`, not `can_edit_group?`/`can_admin_group?` — granting
Site Moderator is admin-only in core, and this mirrors that (a moderator with
`moderators_manage_groups` on does not get to grant Batch Moderator).

**`/g` groups directory — full exclusion, not just de-cluttering**
(`app/controllers/groups_controller.rb`, `app/serializers/group_show_serializer.rb`):
- `GroupsController#index` excludes every `batch_moderation_group`-flagged
  group from the `/g` listing entirely, for everyone including staff (gated by
  `SiteSetting.enable_batch_moderation`) — the original motivation for this
  whole redesign (`bm-*` groups cluttering the page admins use for real
  groups).
- Direct navigation to `/g/:name` for a batch group still loads — useful for
  audit/debug — but is now genuinely **read-only for everyone**, staff and the
  cohort's own owners included. `can_edit_group?` above blocks every mutation
  endpoint server-side (`add_members`, `add_owners`, `remove_member`, and
  `Admin::GroupsController#remove_owner`, all gated by
  `ensure_can_edit!`/`ensure_can_edit_group!`), but the frontend's own
  "Manage" tab, "Add Users" button, and the member-row owner-toggle dropdown
  are keyed off a *separate* pair of fields — `can_admin_group`/
  `is_group_owner` — that `can_edit_group?` alone doesn't touch, and would
  otherwise still render as clickable (and just 403 when clicked) for an
  admin, or for the cohort's own owner viewing their own group. `GroupShowSerializer`
  forces both `can_admin_group` and `is_group_owner` to `false` for batch
  groups specifically, which is what actually hides the Manage tab
  (`canManageGroup` in `frontend/discourse/app/controllers/group.js`), the
  "Add Users"/bulk-select controls (`group/index.gjs`), and the wrench
  dropdown's makeOwner/removeOwner items (`group-member-dropdown.js`) — all
  three key off those two fields, not `can_edit_group`. The group's Delete
  button (admin-only, unrelated to `can_admin_group`) gets its own explicit
  `is_batch_moderation_group` guard in `frontend/discourse/app/templates/group.gjs`.
  `is_group_owner_display` (a separate, purely informational "you're an
  owner" badge field, not a permission gate) is left showing real ownership.

**Admin Users list — reachable by a non-staff Batch Moderator**
(`app/controllers/admin/users_controller.rb`, `config/routes.rb`,
`lib/staff_or_batch_moderator_constraint.rb`):
- `/admin/users/list` and `/admin/users/list/:query` are declared as
  standalone routes *outside* the `StaffConstraint`-gated `/admin` namespace,
  pointing at the same `admin/users#index` action, gated instead by
  `StaffOrBatchModeratorConstraint` (delegates to `StaffConstraint` first, so
  a plugin's `custom_staff_check` extensibility point still applies to staff
  on this route same as every other `/admin` route; falls back to "owns at
  least one batch group" for non-staff). `Admin::UsersController` itself
  `skip_before_action :ensure_staff, only: :index` +
  `before_action :ensure_staff_or_batch_moderator, only: :index` — every
  other admin action stays exactly as staff-only as before.
- For staff, `index_for_staff` is unchanged from core plus two additions:
  cohort filters (`filters`/`staff_only` params, ported from `/u` via a new
  shared `lib/cohort_filter.rb` module that both `AdminUserIndexQuery` and
  `DirectoryItemsQuery` now delegate to — `DirectoryItemsQuery`'s own filter
  methods are a pure refactor onto the same module, no behavior change), and
  a read-only Batch Moderator icon (`is_batch_moderator` on
  `AdminUserListSerializer`, batched via `GroupSync.batch_moderator_user_ids`)
  next to the existing admin/moderator icons — same as "similar to site
  Moderators," not a new connector.
- For a Batch Moderator, `index_for_batch_moderator` **force-scopes** the
  query server-side to `GroupSync.owned_batch_groups(current_user)`'s member
  ids, ignoring any `filters`/`query` the client sends (can't widen their own
  view), and renders through a new `BatchModeratorUserListSerializer`
  (`< BasicUserSerializer`, not `AdminUserListSerializer` even via conditional
  gating — a separate class means no staff-only field, e.g. email/IP/
  suspend-silence reasons, can leak through via a missed branch). Exposes only
  `username, avatar_template, trust_level, created_at, last_seen_at,
  is_batch_moderator`. No cohort filter dropdowns are shown to this viewer —
  nothing to filter across, they only ever see their one cohort.

**Grant/Revoke Batch Moderator — admin-only, on the user detail page**
(`app/controllers/admin/users_controller.rb#grant_batch_moderator`/
`#revoke_batch_moderator`, routed inside the admin namespace under
`AdminConstraint`): calls `guardian.ensure_can_grant_batch_moderator!`/
`ensure_can_revoke_batch_moderator!`, 404s if the target has no cohort group
(their cohort could have been resynced in between the check and the action),
logs via `StaffActionLogger#log_custom`, and fires
`Notifier.notify_moderator_status_change`. Frontend: a "Batch Moderator: Yes/No"
row with a Grant/Revoke button on the admin user detail page
(`admin/templates/admin-user/index.gjs`), alongside the existing Grant/Revoke
Moderation and Grant/Revoke Admin rows, same pattern.

**Reachability for the suspend/silence/report path** (unchanged from the
original commit): a new, non-admin controller
(`app/controllers/batch_moderation_controller.rb`, `requires_login`) exposes
`PUT /batch-moderation/users/:id/suspend`, `/silence`, and
`POST /batch-moderation/users/:id/report` — reusing the exact same
`User::Suspend`/`User::Silence` service objects `Admin::UsersController` uses,
whose own policies call the (now extended) `guardian.can_suspend?`/
`can_silence_user?`.

**Report path** (unchanged): `report` creates a `ReviewableBatchModerationReport`
via `.report!`, landing in the normal staff review queue with Agree/Disagree
actions.

**Frontend, user-card surfaces** (unchanged): `user-card-contents.gjs`'s
Suspend/Silence/Report buttons gated on `user.can_batch_moderate`/
`can_batch_report`; `modal/batch-moderation-penalty.gjs`/
`modal/batch-moderation-report.gjs`; the shield badge connectors near
usernames gated on `is_batch_moderator`.

**Notifications** (`lib/batch_moderation/notifier.rb`) — extended beyond the
original suspend/silence/report notifications with two more entry points,
both notifying **admins + site moderators + the affected cohort's current
Batch Moderators**, every time (not scoped down to just that cohort's own
peers), via the same `Notification::Action::BulkCreate` + background email
job pattern (`Jobs::BatchModerationNotifyCohortChangeEmail`/
`NotifyStatusChangeEmail`, new `BatchModerationMailer` templates
`cohort_change`/`status_change` alongside the original `action_taken`):
- `notify_cohort_change(user:, group:, joined:)` — hooked into `GroupSync.sync`
  itself, firing only on an actual membership change (never a no-op sync).
- `notify_moderator_status_change(actor:, user:, group:, granted:)` — fired
  from the admin grant/revoke actions (`actor` present), from
  `auto_promote_if_understaffed` (`actor: nil`), and from `GroupSync.sync`
  when a cohort change implicitly strips an existing owner's status
  (`actor: nil`) — so a Batch Moderator losing their role via a profile change,
  not just an explicit admin revoke, still notifies everyone.

**Users directory cohort filters** (`app/controllers/directory_items_controller.rb`,
`lib/directory_items_query.rb` → `lib/cohort_filter.rb`,
`frontend/discourse/app/{controllers,routes,templates}/users.js|gjs` →
`frontend/discourse/app/lib/cohort-filter-fields.js`): unchanged in behavior
from the original commit (College/Batch/Branch or Vidyalaya/Batch dropdowns, a
`staff_only` toggle, `is_batch_moderator` on `DirectoryItemSerializer`) — the
query-building logic was extracted into the shared `CohortFilter` module above
so the admin users list could reuse it verbatim, and the frontend field-config
computation was extracted into `cohort-filter-fields.js` so both `/u` and the
admin list controller import one implementation instead of duplicating it.

**One-time backfill** (`lib/tasks/batch_moderation.rake`,
`batch_moderation:resync_cohorts`): the cohort-key redesign (institution
always required, Student/Staff split) doesn't retroactively re-key existing
users — that only happens on their next profile save. This manual,
post-deploy rake task iterates every user on every site
(`RailsMultisite::ConnectionManagement.each_connection`) calling
`GroupSync.sync(user, notify: false)` (suppressed — re-keying every user on
the site would otherwise fire a leave+join, and possibly a status-change,
notification to every staff member and cohort owner, for every single user),
then destroys now-orphaned zero-member batch groups. Not run automatically.

**Existing-user migration off the old blanket Site Moderator system** (same file,
two more one-time, idempotent, dry-run-by-default rake tasks — `DRY_RUN=0` to
write, otherwise they only print what they'd do): `batch_moderation:backfill_member_type`
finds-or-creates `SiteSetting.batch_moderation_member_type_field_name` (dropdown,
required, shown on profile/signup/card) and its two option values on each site,
then sets it to `"Alumni/Student"` or the site's configured staff label
(`SiteSetting.batch_moderation_staff_type_values`) for every user whose value is
currently blank — skipping (not overwriting) anyone who already has one set. A
user is classified as Student iff they have both `Batch` and every configured
Student-only field present (`GroupSync.find_student_only_fields`, which resolves
to `[Branch]` on a college site and `[]` on a site without one — the same site-agnostic
mechanism the cohort-key algorithm itself uses, so no site name is hardcoded
anywhere in the task). `batch_moderation:revoke_site_moderators` then strips
Discourse's core `moderator` flag from every non-admin user, via the same
`user.revoke_moderation!` the admin "Revoke Moderation" button already calls —
retiring the old blanket-grant system now that Batch Moderator is the narrower
replacement. Run order matters: `backfill_member_type` must run *before*
`resync_cohorts` (the cohort-key algorithm's Student/Staff branch reads the field
it backfills), moderator revocation has no dependency on either and is best run
last. See `spec/tasks/batch_moderation_spec.rb` for the full behavior matrix.

**Site settings** (`config/site_settings.yml`, area `group_permissions`):
`enable_batch_moderation` (default off), `batch_moderation_auto_promote_count`
(default 10), `batch_moderation_batch_field_name` (default `"Batch"`),
`batch_moderation_secondary_field_names` (list, default `"Branch"` — changed
from `"Branch|Vidyalaya"`), `batch_moderation_institution_field_names` (list,
default `"College|Vidyalaya"`, new), `batch_moderation_member_type_field_name`
(default `"I am"`, new), `batch_moderation_staff_type_values` (list, default
`"Dean/Professor/Staff"`, new).

### Edge cases

- **Peer-owner exclusion**: two owners of the same batch group cannot moderate
  each other (`Moderator.can_moderate?`), preventing a moderation arms race
  within a cohort — but either can still `report` the other to real staff.
- **Staff targets are always exempt**: `can_moderate?`/`can_report?` both
  return false if `target.staff?`, regardless of group membership.
- **Auto-promote count is generous by default (10)**: on a small/fresh cohort
  group, nearly every member gets auto-promoted to owner until the group
  reaches 10 owners — intentional for bootstrapping, but means "batch
  moderator" isn't necessarily hand-picked on a young group; worth tuning down
  per-site if that's a concern (also why some specs override this to `0`).
- **Staff-type cohorts are institution-wide**: a Staff-type member's key drops
  Batch/Branch entirely, so *all* Staff-type members at the same institution
  share one cohort group regardless of department — by design (see
  Requirement), but worth knowing before assuming every cohort group maps to
  a Batch/Branch pair.
- **Cohort-key upgrades need the backfill task**: turning on the member-type
  field, or changing which fields count as "institution"/"secondary," doesn't
  retroactively re-key anyone already assigned to a group under the old key —
  run `batch_moderation:resync_cohorts` after such a change, or wait for each
  user's next profile save.
- **Cohort completeness**: a user is only synced into a group once the
  institution value (and, for Student-type members, the Batch value) is
  present; a half-filled profile is not assigned to any batch group.
- **Disabling the feature is non-destructive**: turning `enable_batch_moderation`
  off makes every Guardian grant and the admin-list reachability check inert
  immediately (`owned_batch_groups` returns empty), but existing batch groups
  and their membership are left alone (no cleanup job) — re-enabling picks
  back up where it left off.
- **The old `/g`-page grant/revoke workflow is fully retired, not merely
  hidden**: this was the original commit's design (toggle owner status via
  `/g/:name` → Manage → Membership) and its own documented follow-up bug (a
  batch moderator could see that Manage UI and get a 403 using it) — both are
  now moot, since nobody, staff included, sees editable Manage UI on a batch
  group at all (see the `/g` exclusion section above).

---

## 2. Calendar College Filter (Forum Event / Calendar Separation)

*(originally: `feat : Calendar College Filter`)*

### Requirement

The `discourse-events` plugin's calendar needed to let events be scoped to a
single cohort ("only my college's events") while still allowing an organizer
to mark an event as visible to everyone regardless of college — a "Forum
event" toggle — plus a filter control on the calendar itself to narrow the view
to one cohort.

### Implementation

- `plugins/discourse-events/lib/discourse_events/calendar_separation.rb`
  defines `RESERVED_CUSTOM_FIELD_KEY` (`_calendar_separation_value`) and
  `value_for_user(user)` (reads the user's College/Vidyalaya-equivalent field).
- `Event::SyncFromPost#upsert_event`
  (`plugins/discourse-events/app/services/discourse_events/events/event/sync_from_post.rb`)
  stamps this reserved custom field on every event sync:
  - If the raw `[event]` BBCode block has `forum-event="true"`, the reserved
    field is **deleted** — the event is visible to everyone.
  - Otherwise, it's set from `existing_separation_value.presence ||
    CalendarSeparation.value_for_user(post.last_editor)` — a brand-new event
    gets the creator's value; a legacy event with no value yet gets the
    *current editor's* value (not the original author's) the first time
    someone touches it; an event that already has a value keeps it even if a
    different editor with a different college saves the post again.
  - The reserved key is exempted from `Event#allowed_custom_fields` validation
    (`plugins/discourse-events/app/models/discourse_events/events/event.rb`),
    since it's system-managed, not something a client is allowed to send
    directly.
- `plugins/discourse-events/lib/discourse_events/events/finder.rb` adds
  `filter_by_calendar_separation_value`: given `params[:calendar_separation_value]`,
  matches events whose reserved field equals that value **or is null** (a
  forum event, with the field cleared, always shows regardless of which
  cohort filter is active).
- `calendar-separation-filter.gjs` — new dropdown component on the calendar
  (`full-calendar.gjs`/`upcoming-events-calendar.gjs`) listing the values seen
  on the current site; `findSeparationField(site)` (used by the "Forum event"
  checkbox's visibility too) hides the whole feature entirely on sites where
  no separation field is configured at all.
- `post-event-builder.gjs`'s Advanced settings modal gets a "Forum event"
  checkbox ("Show this event to everyone, regardless of college"), wired via
  the existing generic `syncFieldToEvent` action — no new dedicated handler
  needed. `compact-event-editor.gjs` threads `forumEvent` through its
  tracked state/`currentState`/`openAdvanced` round-trip alongside the
  existing fields.
- `basic_event_serializer.rb` exposes `forum_event` (mirrored in the
  `events_index_response.json`/`events_index_detailed_response.json` API
  schema fixtures).

### Edge cases

- **`upsert_event` must use the raising `update_with_params!`, not the
  non-raising `update_with_params`**: `Event#apply_params_for_status` (a
  shared upstream method) returns `self` on both success *and* a rejected save
  — it relies on the non-bang branch having populated `.errors` for callers to
  notice. A save rejected by something that does *not* add to `.errors` (e.g.
  a halted `before_save` callback) would then look like a valid, saved event.
  The fix: use `update_with_params!` and rescue `ActiveRecord::RecordInvalid`,
  returning `e.record` (same object, same populated `.errors` as before for
  ordinary validation failures) — but anything that fails *without* populating
  errors now raises loudly instead of silently no-op'ing. Verified live: a
  "Forum event" post persists `custom_fields: {}`; a normal post persists
  `custom_fields: {"_calendar_separation_value": "<value>"}`.
- **Legacy events with no separation value**: the *editor*, not the original
  author, determines the value the first time the reserved field gets set —
  intentional (the person actually setting it should be the one whose cohort
  it reflects), but means re-saving an old post can retroactively cohort-scope
  it to whoever happens to edit it next.
- **A site with no configured secondary field** (neither Branch nor Vidyalaya
  present) sees no "Forum event" checkbox and no calendar filter at all —
  the whole feature is a no-op rather than showing a broken/empty control.

---

## 3. Enhanced Onboarding (Registration, Invitation & Login)

*(originally: `feat : Enhaced onboarding(registeration, invitation and login) process`)*

Bundles several distinct login/signup UX and infra pieces:

### 3a. Bulk-invite CSV `allow_any_email` column

**Requirement**: let an admin bulk-invite a CSV row that isn't bound to one
exact email address — e.g. inviting "whoever holds this role" rather than a
specific mailbox — while still tracking who it was actually sent to and rate
limiting it like any other invite.

**Implementation** (`app/jobs/regular/bulk_invite.rb`,
`app/jobs/regular/invite_email.rb`, `app/mailers/invite_mailer.rb`):
- New optional CSV column `allow_any_email`; parsed defensively —
  `ActiveModel::Type::Boolean#cast` fails *open* (anything not in its narrow
  `FALSE_VALUES` list casts to `true`), which is wrong for a security-relevant
  flag filled in free-text by an admin, so only an explicit truthy spelling
  (`true/t/1/yes/y`, case-insensitive) is treated as true.
- When true, the generated `Invite` is created **unbound**: `email: nil`,
  `description: <the CSV row's email>` (keeps it visible on the admin
  Pending/Redeemed list even though it's no longer bound). An unbound invite
  is an "invite link" per `Invite#is_invite_link?` — redeemable by *any* email
  address (see `InvitesController#perform_accept_invitation`,
  `InviteRedeemer#can_redeem_invite?`).
- Delivery is handled explicitly via `to_override` on `Jobs::InviteEmail`,
  since `Invite.generate` only auto-sends when `email` is present.
  `InviteEmail#execute` resolves the actual recipient as
  `args[:to_override] || (invite.email.blank? ? invite.description.presence : nil)`,
  validating it's a real email address before sending rather than mailing
  garbage or crashing on nil.
- `emailed_status` is explicitly set to `:sending` via `update_column` (not
  the model's own auto-enqueue path, to avoid a double-send), so
  `resend_all_invites` doesn't treat an unbound invite as "never emailed" and
  skip it forever.
- Rate limiting: `Invite.generate`'s own per-day reinvite limiter only runs
  when `email` is present, which `allow_any_email` rows never satisfy by
  design — so the job replicates the exact same limiter key
  (`reinvites-per-day-<sha256 of downcased email>`) so bound and unbound
  invites to the same address share one daily budget instead of the flag
  bypassing rate limiting entirely.

**Edge cases**:
- User fields / locale prefilled on the CSV row are **not supported** together
  with `allow_any_email` (a pre-created staged user would only ever be found
  and unstaged when the redeemer's email matches the invite's — which never
  happens for an unbound invite — leaving a dangling staged user and silently
  discarding the prefill). The job detects this combination and logs a warning
  instead of silently dropping the data.
- A `bulk_pending` invite's delivery is deliberately *not* double-triggered
  here — `Jobs::ProcessBulkInviteEmails` already re-enqueues those on its own
  throttle, and `Jobs::InviteEmail` already has the `description` fallback.

### 3b. Invite acceptance page redesign

`frontend/discourse/app/templates/invites/show.gjs` restructured into a
two-column `login-body`/`has-alt-auth` layout: existing form on the left
(`login-left-side`), a right-hand social-login panel (`login-right-side`,
`LoginButtons`) shown whenever `showSocialLoginButtons` is true — social login
offered alongside the form whenever a provider is configured, not only when
it's the *sole* option, mirroring `signup.js`'s `showRightSide`.
DiscourseConnect is excluded (it forces its own SSO redirect, for which social
buttons would be a confusing non-functional alternative).

### 3c. OTP confirmation page (mobile app handoff)

`app/views/session/one_time_password.html.erb` redesigned from a bare
form+button into a 3-stage UI: a spinner (auto-submit expected within ~1s,
driven by JS the mobile app injects into the page), a fallback manual "Confirm"
button revealed only if nothing has auto-submitted after a few seconds, and a
"still stuck?" reload prompt as a last resort. `window.__otpAutoSubmit()` is
the single guarded submit path — the injected auto-submit call and a manual
tap are both funneled through it with a `submitted` flag, so a race between
them can't double-POST the same one-time token (a second POST after the first
already succeeded would otherwise report the token as invalid, producing a
false error for the user).

### 3d. Device-auth `platform` threading

The QR-code-based device-linking flow (`UserApiKey::DeviceAuth::{CreateRequest,
Grant,RequestValidator,KeyCreator}`) gained the same `platform` attribute the
direct API-key flow uses (see §4), validated against
`UserApiKey::ALLOWED_PUSH_PLATFORMS` and threaded through to the created key's
`push_url` column — so push registration works whether the mobile app links
by same-device redirect or by scanning a QR code shown on desktop.

### Edge cases

- The OTP page's manual fallback button only appears if nothing has submitted
  yet — if a submit is genuinely just slow (not stuck), the timeout check
  early-returns so the user can't race a slow in-flight request with a second
  manual one.

---

## 4. Mobile Notification Integration

*(originally: `feat : Mobile Notification Integration`)*

### Requirement

Replace the previous generic "web push relay" pusher (`HubPushNotificationPusher`,
removed) with direct native push delivery to iOS (APNs) and Android (FCM), so
the mobile app receives push notifications without a third-party relay
service in the loop.

### Implementation

- **Repurposed column, not a new one**: `UserApiKey#push_url` used to store a
  relay webhook URL; it's repurposed to store the platform string (`"ios"` or
  `"android"`) instead — `push_url IN ('ios', 'android')` is now how
  `UserApiKey.push_clients_for(user)` finds active push-capable keys, replacing
  the old `allowed_user_api_push_urls` substring-match allowlist entirely.
- New `platform` request param (`user_api_keys_controller.rb`,
  `user-api-key-new.js` controller/route) is what actually gets stored into
  `push_url`; validated against `UserApiKey::ALLOWED_PUSH_PLATFORMS = %w[ios android]`.
- `app/services/apns_push_notification_pusher.rb`: builds an `Apnotic`
  connection from `SiteSetting.apple_pem`/`apple_key_id`/`apple_team_id`,
  pushes to every iOS client for the user. If APNs responds `BadDeviceToken`
  (common for debug/TestFlight builds registered against the sandbox rather
  than production APNs), retries once against the sandbox endpoint before
  giving up, reusing one connection per push cycle (opened lazily, closed in
  an `ensure`).
- `app/services/fcm_push_notification_pusher.rb`: builds an OAuth2 JWT-bearer
  assertion from `SiteSetting.fcm_service_account_json` (a Firebase service
  account key), exchanges it for an access token cached for ~55 minutes
  (Google's tokens are valid 1 hour — refreshed a bit early), and POSTs to the
  FCM v1 HTTP API per Android client.
- `Jobs::DeliverPushNotification` now calls both
  `FcmPushNotificationPusher.push`/`ApnsPushNotificationPusher.push`
  unconditionally alongside the existing web-push path, rather than the single
  `HubPushNotificationPusher.push` it used to call.
- New site settings (`user_api` category): `fcm_service_account_json`
  (`textarea: true, secret: true`), `apns_bundle_id`, `mobile_stable_version`
  (`client: true`).
- Bonus fix bundled in this commit: `redirect_uri_for` in
  `user_api_keys_controller.rb` now returns a friendly
  `"the mobile app"` label (`user_api_key.redirect_target_mobile_app`)
  for any `auth_redirect` whose URI scheme isn't `http`/`https` — a raw custom
  scheme like `myapp://callback` used to be shown to the user verbatim, which
  isn't a meaningful "you'll be redirected to X" message for a native app deep
  link.

### Edge cases

- Both pushers **no-op silently** (not an error) if their respective site
  setting is blank — a site that hasn't configured FCM/APNs credentials yet
  just doesn't push, rather than failing.
- Both pushers catch and log (never raise) their own delivery exceptions per
  client — one bad/expired device token doesn't stop delivery to the user's
  other registered devices in the same push cycle.
- FCM's access token is memoized both in-process (`@service_account` hash
  keyed by the raw JSON, avoiding re-parsing) and in `Discourse.cache`
  (shared across processes) — a config change to the service account JSON
  invalidates the in-process memo automatically since it's keyed by the JSON
  string itself, but the *cached* token from the old credentials remains valid
  under the old cache key until its ~55-minute TTL expires.

---

## 5. Allow Moderators to Bulk-Invite via CSV

*(originally: `Allow moderators to bulk invite users via CSV`)*

### Requirement

Bulk invite-from-file was hard-coded to admins only, both server- and
client-side, even though `invite_allowed_groups` already lets moderators send
individual invites — an inconsistent permission boundary.

### Implementation

- `lib/guardian/invite_guardian.rb#can_bulk_invite_to_forum?`: `is_admin?` →
  `is_staff?`.
- `CurrentUserSerializer` exposes the permission to the client:
  `can_bulk_invite_to_forum` (always `true` when included) gated by
  `include_can_bulk_invite_to_forum? { scope.can_bulk_invite_to_forum? }` —
  the standard Discourse serializer pattern for a boolean that should be
  entirely absent from the JSON (not just `false`) when the user lacks the
  permission.
- `user-invited/show.js#canBulkInvite` switched its dependent key and check
  from `currentUser.admin` to `currentUser.can_bulk_invite_to_forum`.

### Edge cases

- None specific to this change beyond the permission boundary itself — this
  is a pure widen-the-gate change reusing an already-existing capability
  (`invite_allowed_groups`) rather than introducing new logic.

---

## 6. Auth Custom Field Validation — Plugin Modifier Hooks

*(originally: `feat : auth custom field validation fix`)*

### Requirement

Give a plugin (the sibling `nvs-authentication-validations` plugin) a clean
extension point to conditionally exempt a specific signup `UserField` from
being "required", without hacking `UsersController`'s core validation
directly — needed for cases like a particular email domain not needing to
fill in a Batch/College field at signup.

### Implementation

`app/controllers/users_controller.rb` wraps both places a required-field
check happens with `DiscoursePluginRegistry.apply_modifier`:
- **Signup** (`create`): `apply_modifier(:user_field_required_for_signup,
  f.required?, f, params[:user_fields])` — a registered modifier receives the
  field's own `required?` value plus the field object and the raw submitted
  params, and returns whether it should actually be enforced.
- **Profile update** (`update`): same pattern via
  `:user_field_required_for_update`, additionally passed the `user` being
  updated.

With **no modifier registered**, `apply_modifier` returns the original value
unchanged — signup/update validation behaves exactly as before this change
(verified by dedicated specs asserting the field is still blocked). A plugin
opts in by calling `DiscoursePluginRegistry.register_modifier(plugin, :user_field_required_for_signup) { |required, field, submitted_fields| ... }`.

### Edge cases

- This is a pure extension point — it cannot, on its own, ever *relax*
  validation; it only does so once a plugin explicitly registers a modifier
  that returns `false` for a specific field. No behavior change ships with
  this commit alone.
- The update-path modifier receives the target `user`, but the signup-path
  modifier does not (the user doesn't exist yet at that point) — a modifier
  shared between both hooks needs to handle a possibly-absent `user` argument.

---

## 7. Local Multisite Configuration & Dev Workflow

*(originally: `feat : Trigger production deployment and local changes`)*

Adds `config/multisite.local.yml` (three local Postgres databases —
`nitians_forum`, `iitians_forum`, `navodians_forum` — mapped to
`*.local` hostnames for genuine multisite local development, mirroring
production's per-site database split) and `docs/LOCAL.md`, documenting that
local dev requires **two** processes running together: the Rails/Puma server
(`DISCOURSE_MULTISITE_CONFIG_PATH=config/multisite.local.yml
DISCOURSE_REDIS_HOST=localhost RAILS_ENV=development bin/rails server -p 3000`)
and the frontend bundler (`pnpm --dir frontend/discourse start`) — the site
renders a "Frontend build error" page if the bundler isn't running, and
`bin/rake multisite:migrate` (not plain `bin/rake db:migrate`, which only
targets the "default" connection) is required to apply migrations across all
three site databases.

Also adds `workflow_dispatch` to `.github/workflows/deploy.yml` (manual deploy
trigger) and the `redirect_target_mobile_app` friendly-label behavior
described in §4 (this is where that logic actually originates, ahead of the
Mobile Notification Integration commit).

---

## 8. Production Deployment Infrastructure

*(originally: `Phantix Deployment`)*

Adds `.github/workflows/deploy.yml` (CI deploy pipeline on push to `master`),
`DEPLOYMENT.md` (full runbook — AWS Lightsail + RDS Postgres + S3 + CloudFront
+ SES infra for navodians.com, SSH access, first-time server bootstrap,
`containers/app.yml` credential placeholders, Let's Encrypt cert renewal/
troubleshooting), `NOTES.md`, and `config/multisite.yml` (the production
multisite config, pointing at real RDS hosts — distinct from the
`multisite.local.yml` added later in commit 7 for local dev). See
`DEPLOYMENT.md` directly for the full operational runbook rather than
duplicating it here.

### Edge case worth flagging

`config/multisite.yml`'s production DB hosts are unreachable from a local
dev machine — running any Rails command locally *without* explicitly
overriding `DISCOURSE_MULTISITE_CONFIG_PATH` to `config/multisite.local.yml`
(or `spec/fixtures/multisite/two_dbs.yml` for the test suite) will hang
trying to connect to production RDS at boot (site-settings refresh iterates
every configured site's DB unconditionally once multisite mode is active).
