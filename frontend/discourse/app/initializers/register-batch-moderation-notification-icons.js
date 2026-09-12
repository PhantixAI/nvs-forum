import { replaceIcon } from "discourse/lib/icon-library";

// The batch moderation notification types (Notification.types in
// app/models/notification.rb: batch_moderation_action, batch_moderation_cohort_change,
// batch_moderation_status_change) never had an entry in icon-library.js's REPLACEMENTS
// map, so `dIcon("notification.<type>")` had nothing to resolve and rendered no icon
// at all in the notification menu.
export default {
  initialize() {
    // A batch moderator took a moderation action (suspend/silence/report) -- notifies
    // staff. Matches the "shield-halved" icon already used elsewhere for moderation
    // reports (app/models/concerns/reports/users_by_type.rb).
    replaceIcon("notification.batch_moderation_action", "shield-halved");

    // A user's cohort changed (joined/left a batch group) -- a membership change,
    // matching the "users" icon already used for other membership notifications.
    replaceIcon("notification.batch_moderation_cohort_change", "users");

    // Batch Moderator status granted/revoked -- reuses the custom "user-tie" icon
    // already registered for this feature's Staff/Batch-Moderator badge elsewhere.
    replaceIcon("notification.batch_moderation_status_change", "user-tie");
  },
};
