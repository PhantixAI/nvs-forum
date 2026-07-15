import Controller from "@ember/controller";
import { computed } from "@ember/object";
import { i18n } from "discourse-i18n";

export default class UserInvitedController extends Controller {
  // Set by user-invited/show's _refetch alongside invitesCount. A domain
  // filter can legitimately narrow an existing user's counts to zero, which
  // must still render "(0)" -- falling back to the bare label (as happens
  // for a genuinely invite-less user) would shrink the tab strip and shift
  // it, since all three tabs lose their count at once.
  domainFilterActive = false;

  @computed("domainFilterActive", "invitesCount.total", "invitesCount.pending")
  get pendingLabel() {
    if (this.invitesCount?.total > 0 || this.domainFilterActive) {
      return i18n("user.invited.pending_tab_with_count", {
        count: this.invitesCount?.pending,
      });
    } else {
      return i18n("user.invited.pending_tab");
    }
  }

  @computed("domainFilterActive", "invitesCount.total", "invitesCount.expired")
  get expiredLabel() {
    if (this.invitesCount?.total > 0 || this.domainFilterActive) {
      return i18n("user.invited.expired_tab_with_count", {
        count: this.invitesCount?.expired,
      });
    } else {
      return i18n("user.invited.expired_tab");
    }
  }

  @computed("domainFilterActive", "invitesCount.total", "invitesCount.redeemed")
  get redeemedLabel() {
    if (this.invitesCount?.total > 0 || this.domainFilterActive) {
      return i18n("user.invited.redeemed_tab_with_count", {
        count: this.invitesCount?.redeemed,
      });
    } else {
      return i18n("user.invited.redeemed_tab");
    }
  }
}
