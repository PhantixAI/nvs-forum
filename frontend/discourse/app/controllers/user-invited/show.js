/* eslint-disable ember/no-observers */
import { tracked } from "@glimmer/tracking";
import Controller, { inject as controller } from "@ember/controller";
import { action, computed } from "@ember/object";
import { dependentKeyCompat } from "@ember/object/compat";
import { service } from "@ember/service";
import { observes } from "@ember-decorators/object";
import CreateInviteBulk from "discourse/components/modal/create-invite-bulk";
import ResendInviteModal from "discourse/components/modal/resend-invite";
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

  /** @type {string | null} */
  @tracked filter = null;
  @tracked selectedDomain = null;
  @tracked selectedStatus = null;

  @tracked selectedDraftIds = new Set();

  /** @type {import("discourse/models/user").default | null} */
  user = null;

  /** @type {import("@ember/object").default & { invites: import("discourse/models/invite").default[], can_see_invite_details: boolean, counts?: { pending: number, redeemed: number, expired: number, total: number }, error?: string } | null | undefined} */
  model = null;

  /** @type {{ pending: number, redeemed: number, expired: number, total: number } | null | undefined} */
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

  // No longer a separate tab -- "draft" is just another value of the
  // Pending tab's own status filter (see statusOptions), reusing its table
  // (and that table's Edit/kebab actions) instead of a dedicated one.
  @dependentKeyCompat
  get inviteDraft() {
    return this.filter === "pending" && this.selectedStatus === "draft";
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

  @computed("invitesCount", "filter", "selectedDomain", "selectedStatus")
  get showSearch() {
    // Keep visible once a filter is selected even if it narrows the count to
    // <=5 (or 0) -- otherwise .user-invite-search's margin-right: auto (the
    // flex anchor that right-aligns .user-invite-buttons) disappears along
    // with it, and the whole button row snaps to the left.
    return (
      this.invitesCount[this.filter] > 5 ||
      Boolean(this.selectedDomain) ||
      Boolean(this.selectedStatus)
    );
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

  @computed("model.available_statuses", "filter")
  get statusOptions() {
    // "draft" is only a meaningful filter on the Pending tab -- Expired has
    // no real draft state (see Invite.expired, which never returns one
    // regardless of status), so offering it there would just be a filter
    // option that always empties the list.
    return (this.model?.available_statuses || [])
      .filter((status) => status !== "draft" || this.filter === "pending")
      .map((status) => ({
        id: status,
        name: i18n(`user.invited.delivery_status_${status}`),
      }));
  }

  @computed("statusOptions", "currentUser.staff", "filter")
  get showStatusFilter() {
    // Redeemed invites don't show a delivery status, so there's nothing to
    // filter by on that tab.
    return (
      this.currentUser?.staff &&
      this.filter !== "redeemed" &&
      this.statusOptions.length > 0
    );
  }

  @dependentKeyCompat
  get allDraftsSelected() {
    const invites = this.model?.invites || [];
    return (
      invites.length > 0 &&
      invites.every((invite) => this.selectedDraftIds.has(invite.id))
    );
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
  async sendNow(invite) {
    try {
      await invite.sendNow();
      this.toasts.success({
        data: { message: i18n("user.invited.invite.send_now_success") },
      });
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  openResendInvite(invite) {
    this.modal.show(ResendInviteModal, {
      model: {
        bulk: false,
        onResend: ({ keywords, aiPersonalization, scheduleSend }) =>
          invite.reinvite({ keywords, aiPersonalization, scheduleSend }),
      },
    });
  }

  @action
  isDraftSelected(invite) {
    return this.selectedDraftIds.has(invite.id);
  }

  @action
  toggleDraftSelected(invite) {
    const selected = new Set(this.selectedDraftIds);
    if (selected.has(invite.id)) {
      selected.delete(invite.id);
    } else {
      selected.add(invite.id);
    }
    this.selectedDraftIds = selected;
  }

  @action
  toggleSelectAllDrafts() {
    this.selectedDraftIds = this.allDraftsSelected
      ? new Set()
      : new Set((this.model?.invites || []).map((invite) => invite.id));
  }

  @action
  sendSelectedDrafts() {
    const inviteIds = [...this.selectedDraftIds];
    if (inviteIds.length === 0) {
      return;
    }

    this.modal.show(ResendInviteModal, {
      model: {
        bulk: true,
        drafts: true,
        confirmMessage: i18n("user.invited.send_selected_confirm", {
          count: inviteIds.length,
        }),
        onResend: async ({
          keywords,
          aiPersonalization,
          scheduleSend,
          allowAnyEmail,
        }) => {
          await Invite.sendDrafts(inviteIds, {
            keywords,
            aiPersonalization,
            scheduleSend,
            allowAnyEmail,
          });
          this.selectedDraftIds = new Set();
          this.toasts.success({
            data: { message: i18n("user.invited.sent_selected") },
          });
          this.send("triggerRefresh");
        },
      },
    });
  }

  @action
  deleteSelectedDrafts() {
    const inviteIds = [...this.selectedDraftIds];
    if (inviteIds.length === 0) {
      return;
    }

    this.dialog.deleteConfirm({
      message: i18n("user.invited.delete_selected_confirm", {
        count: inviteIds.length,
      }),
      didConfirm: () => {
        return Invite.destroyDrafts(inviteIds)
          .then(() => {
            this.selectedDraftIds = new Set();
            this.toasts.success({
              data: { message: i18n("user.invited.deleted_selected") },
            });
            this.send("triggerRefresh");
          })
          .catch(popupAjaxError);
      },
    });
  }

  @action
  reinviteAll() {
    const domain = this.selectedDomain;
    const status = this.selectedStatus;
    const search = this.searchTerm;
    this.modal.show(ResendInviteModal, {
      model: {
        bulk: true,
        confirmMessage: this.#reinviteAllConfirmMessage(domain, status),
        onResend: async ({ keywords, aiPersonalization, scheduleSend }) => {
          await Invite.reinviteAll(domain, status, search, {
            keywords,
            aiPersonalization,
            scheduleSend,
          });
          this.set("reinvitedAll", true);
        },
      },
    });
  }

  @action
  deleteAllInvites() {
    const domain = this.selectedDomain;
    const status = this.selectedStatus;
    const search = this.searchTerm;

    this.dialog.deleteConfirm({
      message: this.#deleteAllInvitesConfirmMessage(domain, status),
      didConfirm: () => {
        return Invite.destroyAllInvites(domain, status, search)
          .then(() => {
            this.toasts.success({
              data: { message: i18n("user.invited.deleted_all") },
            });
            this.send("triggerRefresh");
          })
          .catch(popupAjaxError);
      },
    });
  }

  // A resend is rate-limited per domain and status, so a new filter gets its
  // own "Resend invites" button back.
  @action
  domainChanged(domain) {
    this.selectedDomain = domain;
    this.set("reinvitedAll", false);
    this._refetch();
  }

  @action
  statusChanged(status) {
    this.selectedStatus = status;
    this.set("reinvitedAll", false);
    // Leaving the "draft" status behind a stale checked selection would
    // otherwise resurface (against a now-different row set) if the admin
    // flips back to it later.
    this.selectedDraftIds = new Set();
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
          this.selectedDomain,
          this.selectedStatus
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

  #reinviteAllConfirmMessage(domain, status) {
    const statusLabel =
      status && i18n(`user.invited.delivery_status_${status}`);

    if (domain && status) {
      return i18n("user.invited.reinvite_all_confirm_domain_status", {
        domain,
        status: statusLabel,
      });
    } else if (status) {
      return i18n("user.invited.reinvite_all_confirm_status", {
        status: statusLabel,
      });
    } else if (domain) {
      return i18n("user.invited.reinvite_all_confirm_domain", { domain });
    }
    return i18n("user.invited.reinvite_all_confirm");
  }

  #deleteAllInvitesConfirmMessage(domain, status) {
    const statusLabel =
      status && i18n(`user.invited.delivery_status_${status}`);

    if (domain && status) {
      return i18n("user.invited.delete_all_confirm_domain_status", {
        domain,
        status: statusLabel,
      });
    } else if (status) {
      return i18n("user.invited.delete_all_confirm_status", {
        status: statusLabel,
      });
    } else if (domain) {
      return i18n("user.invited.delete_all_confirm_domain", { domain });
    }
    return i18n("user.invited.delete_all_confirm");
  }

  @debounce(INPUT_DELAY)
  _refetch() {
    Invite.findInvitedBy(
      this.user,
      this.filter,
      this.searchTerm,
      null,
      this.selectedDomain,
      this.selectedStatus
    ).then((invites) => {
      this.set("model", invites);
      // Unlike searchTerm, the domain and status filters also narrow the tab
      // counts (see UsersController#invited). The visible "Pending (n)" tab
      // labels are rendered by the parent user-invited controller's own
      // invitesCount (set once by the route on initial load), not this
      // controller's -- both need updating, this one for showSearch.
      this.set("invitesCount", invites.counts);
      this.userInvitedController.set("invitesCount", invites.counts);
      this.userInvitedController.set(
        "domainFilterActive",
        Boolean(this.selectedDomain || this.selectedStatus)
      );
    });
  }
}
