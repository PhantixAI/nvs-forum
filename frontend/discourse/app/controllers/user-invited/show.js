/* eslint-disable ember/no-observers */
import { tracked } from "@glimmer/tracking";
import Controller, { inject as controller } from "@ember/controller";
import { action, computed } from "@ember/object";
import { dependentKeyCompat } from "@ember/object/compat";
import { service } from "@ember/service";
import { observes } from "@ember-decorators/object";
import CreateInviteBulk from "discourse/components/modal/create-invite-bulk";
import SentInviteEmail from "discourse/components/modal/sent-invite-email";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { removeValueFromArray } from "discourse/lib/array-tools";
import { debounce } from "discourse/lib/decorators";
import { INPUT_DELAY } from "discourse/lib/environment";
import { showCreateInviteModal } from "discourse/lib/invite-modal";
import Invite from "discourse/models/invite";
import { i18n } from "discourse-i18n";

export default class UserInvitedShowController extends Controller {
  @service dialog;
  @service modal;
  @service toasts;
  @service currentUser;
  @service siteSettings;
  @controller("user-invited") userInvitedController;

  @tracked canLoadMore = true;
  @tracked hasLoadedInitialInvites = false;
  @tracked invitesLoading = false;
  @tracked filter = null;
  @tracked selectedDomain = null;

  user = null;
  model = null;
  invitesCount = null;

  reinvitedAll = false;
  searchTerm = "";

  @tracked _canInviteToForumOverride;

  @computed("currentUser.can_invite_to_forum", "user.profile_hidden")
  get canInviteToForum() {
    if (this._canInviteToForumOverride !== undefined) {
      return this._canInviteToForumOverride;
    }
    return this.currentUser?.can_invite_to_forum && !this.user?.profile_hidden;
  }

  set canInviteToForum(value) {
    this._canInviteToForumOverride = value;
  }

  @dependentKeyCompat
  get inviteRedeemed() {
    return this.filter === "redeemed";
  }

  @dependentKeyCompat
  get inviteExpired() {
    return this.filter === "expired";
  }

  @dependentKeyCompat
  get invitePending() {
    return this.filter === "pending";
  }

  @computed("user.id", "currentUser.id")
  get viewingSelf() {
    return this.user?.id === this.currentUser?.id;
  }

  @computed("canInviteToForum", "viewingSelf")
  get canCreateInvite() {
    return this.canInviteToForum && this.viewingSelf;
  }

  @computed(
    "currentUser.can_bulk_invite_to_forum",
    "siteSettings.allow_bulk_invite",
    "viewingSelf"
  )
  get canBulkInvite() {
    return (
      this.currentUser?.can_bulk_invite_to_forum &&
      this.siteSettings?.allow_bulk_invite &&
      this.viewingSelf
    );
  }

  @computed("model")
  get hasEmailInvites() {
    // An allow_any_email invite has no bound email, but is still resendable via its
    // stashed description recipient -- see InvitesController#resend_all_invites, which
    // already includes these. Match that here so the button doesn't disappear just
    // because the visible page happens to be dominated by unbound invites.
    return this.model.invites.some((invite) => {
      return invite.email || invite.description;
    });
  }

  @computed("model")
  get showBulkActionButtons() {
    return this.model.invites.length > 0 && this.currentUser.staff;
  }

  @computed("invitesCount", "filter", "selectedDomain")
  get showSearch() {
    // Keep visible once a domain is selected even if it narrows the count to
    // <=5 (or 0) -- otherwise .user-invite-search's margin-right: auto (the
    // flex anchor that right-aligns .user-invite-buttons) disappears along
    // with it, and the whole button row snaps to the left.
    return this.invitesCount[this.filter] > 5 || Boolean(this.selectedDomain);
  }

  @computed("model.available_domains")
  get domainOptions() {
    return (this.model?.available_domains || []).map((domain) => ({
      id: domain,
      name: domain,
    }));
  }

  @computed("domainOptions", "currentUser.staff")
  get showDomainFilter() {
    // Intentionally not gated on model.invites like showBulkActionButtons --
    // a domain filter that narrows the current tab to zero results must stay
    // visible, or there would be no way to clear it again.
    return this.currentUser?.staff && this.domainOptions.length > 0;
  }

  @observes("searchTerm")
  searchTermChanged() {
    this._refetch();
  }

  @action
  createInvite() {
    showCreateInviteModal(this, { model: { invites: this.model.invites } });
  }

  @action
  createInviteCsv() {
    this.modal.show(CreateInviteBulk);
  }

  @action
  editInvite(invite) {
    showCreateInviteModal(this, { model: { editing: true, invite } });
  }

  @action
  async destroyInvite(invite) {
    try {
      await invite.destroy();
      removeValueFromArray(this.model.invites, invite);
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  destroyAllExpired() {
    this.dialog.deleteConfirm({
      message: i18n("user.invited.remove_all_confirm"),
      didConfirm: () => {
        return Invite.destroyAllExpired(this.user)
          .then(() => {
            this.toasts.success({
              data: { message: i18n("user.invited.removed_all") },
            });
            this.send("triggerRefresh");
          })
          .catch(popupAjaxError);
      },
    });
  }

  @action
  async previewSentEmail(invite) {
    try {
      const model = await Invite.findLatestSentEmail(invite.id);
      this.modal.show(SentInviteEmail, { model });
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  reinvite(invite) {
    invite.reinvite();
    return false;
  }

  @action
  reinviteAll() {
    const domain = this.selectedDomain;
    this.dialog.yesNoConfirm({
      message: domain
        ? i18n("user.invited.reinvite_all_confirm_domain", { domain })
        : i18n("user.invited.reinvite_all_confirm"),
      didConfirm: () => {
        return Invite.reinviteAll(domain)
          .then(() => this.set("reinvitedAll", true))
          .catch(popupAjaxError);
      },
    });
  }

  @action
  domainChanged(domain) {
    this.selectedDomain = domain;
    this._refetch();
  }

  @action
  async loadMore() {
    const model = this.model;

    if (this.canLoadMore && !this.invitesLoading) {
      this.invitesLoading = true;

      try {
        const result = await Invite.findInvitedBy(
          this.user,
          this.filter,
          this.searchTerm,
          model.invites.length,
          this.selectedDomain
        );
        const inviteList = result.invites;

        this.invitesLoading = false;
        model.invites.push(...inviteList);

        if (
          inviteList.length === 0 ||
          inviteList.length < this.siteSettings.invites_per_page
        ) {
          this.canLoadMore = false;
        }
      } finally {
        this.hasLoadedInitialInvites = true;
      }
    }
  }

  @debounce(INPUT_DELAY)
  _refetch() {
    Invite.findInvitedBy(
      this.user,
      this.filter,
      this.searchTerm,
      null,
      this.selectedDomain
    ).then((invites) => {
      this.set("model", invites);
      // Unlike searchTerm, a domain filter also narrows the tab counts
      // (see UsersController#invited). The visible "Pending (n)" tab labels
      // are rendered by the parent user-invited controller's own
      // invitesCount (set once by the route on initial load), not this
      // controller's -- both need updating, this one for showSearch.
      this.set("invitesCount", invites.counts);
      this.userInvitedController.set("invitesCount", invites.counts);
      this.userInvitedController.set(
        "domainFilterActive",
        Boolean(this.selectedDomain)
      );
    });
  }
}
