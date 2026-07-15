import NotificationTypeBase from "discourse/lib/notification-types/base";
import { userPath } from "discourse/lib/url";
import { i18n } from "discourse-i18n";

export default class extends NotificationTypeBase {
  get label() {
    return (
      this.notification.data.actor_username ||
      i18n("batch_moderation.system_actor")
    );
  }

  get description() {
    return i18n(
      `notifications.batch_moderation_status_change.${
        this.notification.data.granted ? "granted" : "revoked"
      }`,
      {
        username: this.notification.data.user_username,
        group_name: this.notification.data.group_name,
      }
    );
  }

  get linkHref() {
    return userPath(this.notification.data.user_username);
  }
}
