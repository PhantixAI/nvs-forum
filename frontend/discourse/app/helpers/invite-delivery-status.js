import { trustHTML } from "@ember/template";
import { i18n } from "discourse-i18n";

const STATUSES = [
  "scheduled",
  "pending",
  "skipped",
  "sent",
  "delivered",
  "bounced",
  "complained",
];

/**
 * Returns a safe HTML pill for an invite's delivery_status (see
 * Invite#delivery_status), or undefined for a status this pill doesn't
 * cover (e.g. null, for invites that never needed an email).
 *
 * @param {string} status - `invite.delivery_status`
 * @returns {string} HTML for the delivery status pill
 */
export default function inviteDeliveryStatus(status) {
  if (!STATUSES.includes(status)) {
    return;
  }

  const html = `
    <div class="delivery-status-pill --${status}">
      ${i18n(`user.invited.delivery_status_${status}`)}
    </div>
  `;

  return trustHTML(html);
}
