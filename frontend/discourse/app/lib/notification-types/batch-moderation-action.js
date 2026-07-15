import NotificationTypeBase from "discourse/lib/notification-types/base";
import { userPath } from "discourse/lib/url";
import { i18n } from "discourse-i18n";

export default class extends NotificationTypeBase {
  get label() {
    return this.notification.data.actor_username;
  }

  get description() {
    return i18n(
      `notifications.batch_moderation_action.${this.notification.data.action}`,
      { username: this.notification.data.target_username }
    );
  }

  get linkHref() {
    return userPath(this.notification.data.target_username);
  }
}
