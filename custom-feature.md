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

## 2. Calendar Event Scope: Batch / College / Forum Event

*(originally: `feat : Calendar College Filter`; redesigned 2026-09-12 from a
boolean "Forum event" toggle into a 3-way scope with real enforcement — see
"v2 redesign" below.)*

### Requirement

The `discourse-events` plugin's calendar needed three visibility tiers for an
event, chosen by its creator via a dropdown next to the "All day" toggle,
defaulting to the narrowest:
- **Batch Event** (default): visible only to users sharing the creator's
  institution (College/Vidyalaya) **and** batch **and** branch.
- **College Event**: visible only to users of that institution.
- **Forum Event**: visible to everyone (in practice, all NITians/IITians
  colleges — Navodians is out of scope for this feature the same way it's out
  of scope for `enable_batch_moderation`'s "Batch"/"Branch" fields).

Unlike the original boolean, this needed to be **real enforcement** (a viewer
in the wrong cohort genuinely cannot see the event), not just an opt-in
narrowing filter on the calendar's own display.

### Implementation

- `plugins/discourse-events/lib/discourse_events/calendar_event_scope.rb` —
  new module, the single source of truth for scope semantics:
  - `SCOPE_CUSTOM_FIELD_KEY` (`_calendar_event_scope`, values `"batch"` /
    `"college"` / `"forum"`) and `COHORT_DIGEST_CUSTOM_FIELD_KEY`
    (`_calendar_batch_cohort_digest`) — two new reserved, system-managed
    custom-field keys alongside the pre-existing `_calendar_separation_value`.
  - `cohort_digest_for(user)` — a 12-char SHA1 digest of the user's full
    institution+batch+branch cohort, computed directly from
    `BatchModeration::GroupSync.cohort_key_for(user)` using the exact same
    digest scheme `GroupSync.deterministic_name` uses for batch-group naming
    — deliberately **independent of `SiteSetting.enable_batch_moderation`**
    (which only gates Group auto-provisioning, not cohort-key computation) and
    of Group membership existing at all. Returns `nil` for a `nil` user, a
    user with an incomplete cohort (e.g. no Batch value), **or a staff-type
    user** — a staff cohort key is institution-only (see
    `GroupSync.cohort_key_for`), which carries no batch/branch distinction at
    all, so it's never treated as a valid "batch cohort" (indistinguishable
    from every other staff member's key at that institution otherwise).
  - `scope_for(custom_fields)` — infers scope for events saved before
    `_calendar_event_scope` existed: absent scope key + absent separation
    value → `"forum"` (the old boolean's "everyone" state); absent scope key +
    present separation value → `"college"` (the old boolean's "college-scoped"
    state). No data migration needed for pre-existing events.
  - `visible_to?(event, user)` — the actual per-viewer predicate, mirrored
    (not literally shared, for performance) by the Finder SQL below.
- `Event::SyncFromPost#upsert_event` stamps all three reserved keys from a new
  raw attribute `event-scope` (replacing `forum-event`), defaulting to
  `"batch"` when absent/unrecognized:
  - `forum` → deletes both the separation value and the cohort digest.
  - `batch` → resolves/stamps the separation value (sticky: keeps the
    existing value across re-edits rather than re-deriving it, same as
    before) and the cohort digest (same sticky rule, new). If the creator's
    digest can't be resolved (incomplete cohort, or staff-type), **collapses
    to `college` scope** instead — an event nobody but its author could ever
    find is a worse failure mode than one slightly too broad.
  - `college` → resolves/stamps the separation value only, sticky, no digest.
- `plugins/discourse-events/lib/discourse_events/calendar_separation.rb`'s
  `configured_field` now delegates to `BatchModeration::GroupSync.find_institution_field`
  (respects `SiteSetting.batch_moderation_institution_field_names`, so it
  resolves "Vidyalaya" too) instead of a hardcoded `"College"` constant.
- `plugins/discourse-events/lib/discourse_events/events/finder.rb` adds
  `filter_by_calendar_event_scope(events, user)`, applied **unconditionally**
  (not opt-in) in `Finder.search`'s chain — real access control, matching each
  scope against the viewer's own institution value / cohort digest via a
  single OR'd SQL clause; a legacy row with a separation value but no scope
  key is matched as `college`, per `scope_for`'s inference. The old
  `filter_by_calendar_separation_value` (param-driven) survives as a
  **voluntary further-narrowing** filter layered on top — it now only ever
  restricts further, never re-opens access the mandatory filter excluded.
- The Event visibility control is a **mandatory** 3-option `eventScope`
  select (replacing the optional "Forum event" checkbox; `@validation="required"`
  on the FormKit field means FormKit never adds its usual blank/"None" option
  here — see `frontend/discourse/app/form-kit/components/fk/control/select.gjs`'s
  `includeNone` logic), always defaulting to Batch Event. It's rendered on
  **two independent surfaces**, both driven by the shared
  `lib/calendar-event-scope.js` (`showEventScope`/`showBatchEventOption`
  helpers, so the two never drift on when the control shows or which options
  it offers):
  - `post-event-builder.gjs`'s Advanced settings modal — a FormKit
    `form.Row`/`row.Col` (size 6/6, collapsing to 12 when the select itself
    is hidden) puts it beside "All day".
  - `compact-event-editor.gjs` — the **inline** editor shown directly under
    the composer right after inserting an event (before ever opening
    Advanced settings). This one isn't FormKit-based; it's a `DNativeSelect`
    (`@includeNone={{false}}`) in a new `.composer-event__all-day-row` flex
    wrapper alongside the existing `DToggleSwitch`, wired through the same
    `#emitChange()` pattern every other field in that component uses.
  Both surfaces read/write the same `eventScope` value end-to-end through
  `discourse-post-event-event.js`, `raw-event-helper.js`, `event-node-view.gjs`,
  and the rich-editor's node schema — the same plumbing `forumEvent` used to
  thread through, generalized to a string enum.
  `plugin.rb` adds `calendar_event_scope_fields` to the `:site` serializer
  (`{ institution:, institution_field_name:, batch: }`) so neither frontend
  surface duplicates the (server-only, `client: false`) batch-moderation
  field-name site settings — `calendar-separation-filter.gjs`'s
  institution-field lookup was similarly generalized off its old hardcoded
  `"College"` constant.
- `basic_event_serializer.rb` exposes `event_scope` (string enum, replacing
  the `forum_event` boolean; mirrored in the API schema fixtures).
- New indexes on `(custom_fields ->> '_calendar_event_scope')` and
  `(custom_fields ->> '_calendar_batch_cohort_digest')` — required, not just
  nice-to-have, since the Finder filter now runs on every list/feed query.

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
  errors now raises loudly instead of silently no-op'ing.
- **Legacy events with no separation value**: the *editor*, not the original
  author, determines the value the first time the reserved fields get set —
  intentional (the person actually setting it should be the one whose cohort
  it reflects), but means re-saving an old post can retroactively cohort-scope
  it to whoever happens to edit it next. The batch cohort digest follows the
  same sticky-first-value rule once set, for the same reason.
- **A site with no configured institution field** (neither College nor
  Vidyalaya present) sees no scope dropdown and no calendar filter at all —
  the whole feature is a no-op rather than showing a broken/empty control. A
  site with an institution field but no Batch field still gets the dropdown,
  just without the "Batch Event" option.
- **A staff-type creator or viewer never participates in batch scope**: their
  cohort key is institution-only, so `cohort_digest_for` is always `nil` for
  them — a staff creator's default "Batch Event" collapses to College scope
  at save time, and a staff viewer can never see anyone else's batch-scoped
  event (even at their own institution), since there's no batch value to
  match against either direction.
- **Direct topic links bypass scope** (pre-existing gap, not introduced by
  this change): `EventsController#show` and the in-topic event card only
  check ordinary topic/category permissions, not `CalendarEventScope`. Closing
  this (via `CalendarEventScope.visible_to?` in the guardian/serializer
  inclusion condition) was deliberately left as a fast-follow, not part of
  this ship, since the literal ask was calendar-list visibility.
- **A no-op edit must never narrow an existing event's scope**: `upsert_event`
  only defaults the raw `event-scope` attribute to `"batch"` for a brand-new
  event (`event.new_record?`); for an existing event it falls back to that
  event's own currently-persisted (or legacy-inferred) scope instead. This
  matters because two of the three editing surfaces —
  `pre-initializers/rich-editor-extension.js`'s node schema and
  `raw-event-helper.js`'s `parseEventAttrs` — default a *missing* attribute to
  `null`, not `"batch"` (unlike `defaultEventState()`, which still defaults a
  genuinely-new event's initial state to `"batch"`), and `buildParams` only
  writes the `eventScope` param when it's actually set (mirroring every other
  optional param in that file) rather than unconditionally forcing `"batch"`
  the way the old boolean's comment used to justify. Without both halves of
  this fix, editing a legacy event through the rich editor or the raw
  composer — even a change unrelated to the event, with the Event visibility
  control never touched — would silently write an explicit `event-scope="batch"`
  attribute into the raw markdown and narrow that event's audience.
  `post-event-builder.gjs`'s own Advanced-settings path was never affected by
  this (it always sources `eventScope` from the server-computed
  `event_scope`, never from raw-text re-parsing), but a narrower version of
  the same risk remains where `compact-event-editor.gjs`'s `openAdvanced()`
  hands a raw-text-derived (possibly-unknown) scope to a fresh
  `DiscoursePostEventEvent` for the modal — that model's own hydration has no
  way to distinguish "brand new" from "existing but client doesn't know yet",
  so it still defaults to `"batch"` for display. This narrower gap requires a
  user to explicitly open Advanced settings on a legacy event and save without
  correcting the pre-selected value; deliberately left unaddressed as
  disproportionate to fix given the architecture.
- **Raw attribute naming**: the raw `[event ...]` BBCode-ish attribute is
  written as `eventScope` (camelCase, matching the JS model property) — it
  does *not* get dasherized until the markdown-it cook step
  (`discourse-markdown/discourse-post-event-block.js`'s `dasherize()`, called
  from its `wrap()` token rule), which is what actually produces the
  `data-event-scope` HTML attribute `Parser::VALID_OPTIONS`'s `:"event-scope"`
  entry matches against. Skimming only the raw markdown source (e.g. in the
  composer's split view) will show `eventScope=...`, not `event-scope=...`;
  that's expected, not a bug.

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

### Extension: Batch Moderator bulk invite via Review Queue

The above widened bulk invite to site moderators (`is_staff?`). Batch
Moderators (section 1) are deliberately weaker — non-staff — so they don't
get the same immediate-processing path. Instead:

- `BatchModeration::GuardianExtension#can_bulk_invite_to_forum?`
  (`lib/batch_moderation/guardian_extension.rb`) grants a Batch Moderator
  access to the same "Create Bulk Invites" UI as staff, but
  `InvitesController#upload_csv` branches on `guardian.is_staff?`: staff are
  unchanged (immediate `Jobs.enqueue(:bulk_invite, ...)`), a Batch
  Moderator's upload instead creates a `ReviewableBulkInvite` and is held
  for admin/moderator approval in the standard Review Queue (`/review`) —
  the review step *is* the access control, no separate toggle needed.
- The reviewable stores **both** the parsed `invites` array **and** the raw
  uploaded CSV bytes (`raw_csv`). This is deliberate: Discourse's stock CSV
  parser silently drops any column that's blank on every row (e.g. an empty
  `groups` column), so reconstructing "what was uploaded" from the parsed
  array alone loses data — the review UI
  (`frontend/discourse/app/components/reviewable/bulk-invite.gjs`) renders
  and downloads `raw_csv` verbatim instead. `upload_csv` also caps the raw
  file at `MAX_BULK_INVITE_CSV_BYTES` (5MB) before persisting it, since
  unlike the parsed array it isn't otherwise bounded by `max_bulk_invites`.
- On approve, the existing `Jobs::BulkInvite` flow runs as normal (including
  its own pre-existing `bulk_invite_succeeded`/`bulk_invite_failed` PM to
  the submitter). On reject, a new `reviewable_bulk_invite_rejected` system
  PM notifies the submitter — previously rejection sent no notification at
  all.
- `Jobs::BulkInvite#get_topic` gained a `@guardian.can_invite_to?(topic)`
  check (it previously had none), consistent with how `get_groups` already
  silently drops unauthorized groups rather than trusting a CSV column
  unconditionally. Matters more now that a lower-trust role's invites can
  reach this job post-approval.
- A Batch Moderator does **not** need to have connected a LinkedIn account
  to bulk-invite — `can_bulk_invite_to_forum?` only checks batch-group
  ownership. An earlier version of this feature added an optional,
  site-setting-gated LinkedIn-connection requirement on top of this; it was
  removed as unwanted. LinkedIn login (`linkedin_oidc`, section 9) is
  unrelated and unaffected by that removal.

### Edge cases (Batch Moderator extension)

- No automated spec coverage yet for `ReviewableBulkInvite`'s
  submit/approve/reject flow or the new guardian methods — verified
  manually this round (console scripts + live browser testing against a
  restored local DB), not via committed specs. Worth closing.

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

---

## 9. LinkedIn OIDC Login Fix — `client_secret` Missing

### Requirement

LinkedIn login (`linkedin_oidc`, used both for user sign-in and as the
identity check for section 5's Batch Moderator LinkedIn gate) was failing
on production with `OAuth2::Error, invalid_request: A required parameter
"client_secret" is missing` during the token-exchange callback step.

### Root cause

Not a config issue — the `oauth2` Ruby gem (pinned at 2.0.25 in
`Gemfile.lock`) changed its default `auth_scheme` from `:request_body` to
`:basic_auth` in its 2.0 release. LinkedIn's token endpoint
(`/oauth/v2/accessToken`) only accepts `client_secret` in the POST body, not
an `Authorization: Basic` header, so it never received the secret at all.
Confirmed this is an unpatched gap in upstream Discourse core too (not
something this fork fell behind on).

### Implementation

- `lib/auth/linkedin_oidc_authenticator.rb`: added `auth_scheme:
  :request_body` to the `LinkedInOidc` strategy's `client_options`, pinning
  back the pre-2.0 behavior. Scoped only to this authenticator's own
  `client_options` — mirrors the identical, pre-existing pattern already
  used for GitHub and Facebook in this codebase; does not touch the shared
  `oauth2` gem config or any other authenticator.

### Edge cases

- A separate, earlier production issue on the same login flow
  (`invalid_scope_error`) was a LinkedIn Developer Portal config gap, not
  code — the app needed the "Sign In with LinkedIn using OpenID Connect"
  product added under its Products tab. Worth remembering these are two
  independent failure modes that can both block the same login attempt.

## 10. AI-Personalized, Paced Bulk Invite Emails

### Requirement

Bulk-invite CSV uploads of thousands of college student emails (`.ac.in`
domains) were being flagged as spam — every invite email came from the same
fixed locale-template text, and large batches were fired in bursts of up to
200 at once (see section 3's throttle, `Jobs::ProcessBulkInviteEmails`).
Needed: (1) each recipient's email body text made textually distinct via an
AI language model, following a strict anti-spam style, and (2) every send
spaced out by a random, admin-configurable delay (default 5-15s) regardless
of total CSV size, instead of bursting.

### Implementation (`lib/bulk_invite_personalization/`,
`app/jobs/regular/process_bulk_invite_emails.rb`,
`app/jobs/regular/bulk_invite.rb`)

- New `BulkInvitePersonalization::Generator.personalize(invite)`
  (`lib/bulk_invite_personalization/generator.rb`): builds a
  `DiscourseAi::Completions::Prompt` embedding the anti-spam rules (plain
  text only, under 75 words, no links/markdown/attachments in the generated
  portion, peer-to-peer tone, no jargon/`!`/ALL CAPS/`$`, ends with a
  low-friction question, vary phrasing per call, reference the recipient's
  college only via their email domain — never invent a name) plus the
  admin's `bulk_invite_ai_personalization_template` site setting and the
  recipient's email domain, and calls the site's configured
  `SiteSetting.ai_default_llm_model` (falling back to `LlmModel.last`).
  Fails safe (returns `nil`) at every prerequisite check — plugin/feature
  disabled, blank template, no LLM configured — and rescues any LLM error,
  so a failed generation never blocks the invite from sending via the plain
  template.
- `BulkInvitePersonalization::ResponseValidator.clean(text)`
  (`lib/bulk_invite_personalization/response_validator.rb`): defense-in-depth
  post-processing — strips HTML, hard-rejects (not strip-and-continue) any
  URL/domain, markdown, `!`/`$`/ALL-CAPS content, and enforces the 75-word
  cap by truncating to the last sentence boundary or rejecting outright if
  no clean boundary exists under the limit.
- Generation happens in `Jobs::ProcessBulkInviteEmails`, one invite at a
  time, immediately before send — never in `Jobs::BulkInvite`, which can
  process an entire 10K-row CSV in a single job run; calling the LLM there
  would mean thousands of blocking calls with no pacing. Writing the result
  into `Invite#custom_message` routes through the pre-existing
  `custom_invite_forum_mailer` template (`InviteMailer#send_invite` already
  branches on `custom_message.present?`) with **zero changes** to the
  mailer, `Jobs::InviteEmail`, or any locale template — the join link
  (`%{invite_link}`) is untouched and still always sent.
- `Jobs::ProcessBulkInviteEmails#execute` was rewritten from a
  200-per-minute batch throttle (pull up to `Invite::BULK_INVITE_EMAIL_LIMIT`
  pending invites, fire all their `Jobs::InviteEmail` enqueues at once,
  reschedule after a fixed 1 minute) into a one-at-a-time loop: pick a
  single `bulk_pending` invite via `FOR UPDATE SKIP LOCKED` (safe under
  concurrent executions — a Sidekiq retry, or two overlapping
  `Jobs::BulkInvite` runs — without a separate lock), personalize it, send
  it, then reschedule itself after
  `rand(bulk_invite_email_delay_min_seconds..bulk_invite_email_delay_max_seconds).seconds`
  (both new site settings, default 5/15, cross-validated min ≤ max via
  `BulkInviteEmailDelayMinSecondsValidator`/`...MaxSecondsValidator`).
- `Jobs::BulkInvite#send_invite`: bound invites now always get
  `emailed_status: :bulk_pending` (previously only when the CSV had more
  than `Invite::BULK_INVITE_EMAIL_LIMIT` rows), so pacing and personalization
  apply uniformly regardless of batch size. `allow_any_email` unbound rows
  keep their original `> BULK_INVITE_EMAIL_LIMIT`-gated behavior and
  `to_override` immediate-delivery path untouched — out of scope for this
  feature. `Jobs::BulkInvite#execute` now always enqueues
  `Jobs::ProcessBulkInviteEmails` after processing (a no-op when nothing
  ended up `bulk_pending`).
- `Invite::BULK_INVITE_EMAIL_LIMIT` narrows in scope: it's no longer a batch
  size (replaced by `.limit(1)` in the rewritten job) and no longer governs
  bound-invite throttling at all — it now only gates the `allow_any_email`
  immediate-vs-throttled threshold.
- New site settings (`config/site_settings.yml`, `users` area):
  `bulk_invite_ai_personalization_enabled` (bool, default off — zero
  behavior change for existing sites until an admin opts in and has an LLM
  configured), `bulk_invite_ai_personalization_template` (textarea, hidden
  until personalization is enabled), `bulk_invite_email_delay_min_seconds`
  / `bulk_invite_email_delay_max_seconds` (integers, default 5/15, apply to
  every bulk invite independent of personalization).

### Edge cases

- No LLM configured (empty `LlmModel` table, or the `discourse-ai` plugin
  disabled) is an expected, permanently-supported state, not an error —
  personalization silently no-ops and invites send through the pre-existing
  plain template.
- `allow_any_email` invites are explicitly out of scope: neither
  personalized nor re-paced beyond their pre-existing
  `> BULK_INVITE_EMAIL_LIMIT`-row `bulk_pending` threshold.
- Overlapping `Jobs::BulkInvite` runs (e.g. two CSV uploads close together)
  can produce more than one concurrently-active `ProcessBulkInviteEmails`
  self-rescheduling chain; `FOR UPDATE SKIP LOCKED` prevents any row from
  being double-sent, but pacing guarantees only hold per-chain, not
  globally, under that overlap — accepted as a rare, non-corrupting edge
  case rather than adding a distributed lock.
- A `Jobs::ProcessBulkInviteEmails` crash between marking an invite
  `:sending` and its `enqueue_in` reschedule leaves that one row stuck at
  `:sending` forever — a pre-existing risk in the batch version too,
  unchanged by this work.
- `Jobs.enqueue_in` retains Sidekiq's default retry behavior for this job
  (deliberately not disabled, unlike `Jobs::BulkInvite`'s
  `sidekiq_options retry: false`) — safe because `FOR UPDATE SKIP LOCKED`
  means a retry can't double-claim an already-`:sending`/`:sent` row.

### Extension: Paced Resend All Invites

**Requirement**: `InvitesController#resend_all_invites` (the admin "Resend
All Invites" button) predates this feature and calls `Invite#resend_invite`
— an immediate, undelayed `Jobs.enqueue(:invite_email, ...)` — for every
matching invite in a plain loop. That completely bypasses the throttle
above: triggering it mid-campaign re-sends every already-sent invite as a
duplicate *and* blasts out every still-`bulk_pending` invite all at once,
reproducing the exact burst-send pattern this whole feature exists to
prevent — reachable by a single click.

**Implementation** (`app/models/invite.rb`,
`app/controllers/invites_controller.rb`):

- New `Invite#requeue_for_paced_resend`: the same expiry/invalidation reset
  as `resend_invite`, but sets `emailed_status: :bulk_pending` instead of
  enqueuing `Jobs::InviteEmail` directly. `resend_invite` itself is
  untouched and still used as-is for the single-invite resend action (no
  burst risk there — one admin-triggered email is fine to send immediately).
- `InvitesController#resend_all_invites_paced` (private): iterates the same
  invite scope `resend_all_invites` already used, skips any invite whose
  `emailed_status` is already `bulk_pending`/`sending` (already queued —
  requeuing it would be redundant and risks reordering or duplicating an
  in-flight send), calls `requeue_for_paced_resend` on the rest, and
  enqueues `Jobs::ProcessBulkInviteEmails` once at the end — reusing the
  exact same one-at-a-time, randomly-paced throttle (and AI personalization,
  if enabled) a fresh CSV upload goes through, rather than adding a second
  throttle implementation.
- Gated behind new site setting `bulk_invite_paced_resend_enabled` (default
  **off**, matching `bulk_invite_ai_personalization_enabled`'s
  safe-default-for-existing-sites precedent): `resend_all_invites` branches
  on it, calling `resend_all_invites_paced` when on or falling back to the
  original immediate-send loop when off. A site that never opts in sees
  zero behavior change.

**Edge cases**:

- Re-queuing overwrites `custom_message` the next time
  `Jobs::ProcessBulkInviteEmails` processes the invite: if AI personalization
  is enabled, a resent invite gets a freshly-generated (differently worded)
  note rather than reusing its original one — desirable, since identical
  wording on a resend burst would be exactly the fingerprint risk this
  feature avoids. If personalization is disabled or unavailable at that
  point, `custom_message` is cleared back to blank and the invite sends via
  the plain template, same as any other throttled send.
- Invites deliberately marked `:not_required` via `skip_email` still match
  `resend_all_invites`'s existing scope (`email IS NOT NULL` alone satisfies
  it for a bound invite) and still get requeued/resent when paced resend is
  on — this is unchanged, pre-existing scope behavior from before this
  extension, not something introduced here.
- The pre-existing `bulk-reinvite-per-day` rate limiter (1/day) still
  applies unchanged and limits how often "Resend All Invites" can be
  triggered at all; it does not limit how many invites a single trigger
  requeues.

## 11. Name-Based Usernames at Email-Code Signup + Locked Full-Name Requirement

### Requirement

Batch-moderator promotion notifications (and the cohort-change / action
notifications) link to `/u/<username>`. Email-code signup used to create the
account with a random placeholder (`QuietFalcon34`, or `userN` with random
names off) that the new member then renamed on the "account ready" screen, so
links built from the placeholder went dead. Usernames now start from the
member's own name so there's usually nothing to rename, and links survive a
rename when there is.

### Implementation

- `User::Action::CreateFromVerifiedEmail` derives the username from the name
  first (`UserNameSuggester.suggest(name)`, gated on
  `use_name_for_username_suggestions`, default on): "Rahul Sharma" becomes
  `Rahul_Sharma`, `Rahul_Sharma1` on collision. Only if that yields nothing
  (no name, or one that sanitizes to nothing) does it fall through to the old
  chain: email-based suggestion, random generator, generic `userN`.
- `Jobs::UpdateUsername#update_batch_moderation_notifications` rewrites
  `user_username` / `actor_username` / `target_username` in the three
  `batch_moderation_*` notification types on every rename (core's
  `update_notifications` only knows its own keys). Runs in the existing
  low-priority job; one scan of `notifications` (no index on those keys or on
  `notification_type` alone).
- Migration `BackfillBatchModerationNotificationUsernames` repoints already
  stale notifications by `user_id` / `target_user_id`. Notifications whose user
  no longer exists can't be repaired. Actor names have no id stored, so they
  are only fixed going forward.
- Full name is permanently required: `full_name_requirement` defaults to
  `required_at_signup`, is `hidden`, and `FullNameRequirementValidator`
  rejects any other value (UI, API and `SiteSetting.x =` alike). Migration
  `ResetFullNameAndRandomUsernameSettings` deletes any override of it.
  Specs covering the other modes use `stub_full_name_requirement`
  (`spec/support/full_name_requirement_helper.rb`).
- `enable_random_usernames`, `random_username_adjectives` and
  `random_username_nouns` are hidden from the admin UI. Random names remain the
  fallback for names that can't become a username. The migration also deletes
  any `enable_random_usernames` override so it stays on; customised word lists
  are left in place.

### Edge cases

- Hidden is not locked for the random settings: they can still be changed by
  console or API, unlike `full_name_requirement`.
- `enable_names` is hidden and its override is reset (it must stay on for the
  required name to be collected), but it has no validator: many core and
  plugin specs assign it `false`, so a validator would need dozens of upstream
  spec edits. Like the random settings, console or API can still change it.
- Classic (non-code) signup is unchanged: the member picks their own username
  there.
