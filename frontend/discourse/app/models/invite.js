import EmberObject, { computed, set } from "@ember/object";
import { trackedArray } from "@ember/reactive/collections";
import { isNone } from "@ember/utils";
import { ajax } from "discourse/lib/ajax";
import { userPath } from "discourse/lib/url";
import Topic from "discourse/models/topic";
import User from "discourse/models/user";

export default class Invite extends EmberObject {
  static create() {
    const result = super.create(...arguments);
    if (result.user) {
      result.user = User.create(result.user);
    }
    return result;
  }

  static async findInvitedBy(user, filter, search, offset, domain, status) {
    if (!user) {
      return;
    }

    const data = {};
    if (!isNone(filter)) {
      data.filter = filter;
    }
    if (!isNone(search)) {
      data.search = search;
    }
    if (!isNone(domain)) {
      data.domain = domain;
    }
    if (!isNone(status)) {
      data.status = status;
    }
    data.offset = offset || 0;

    const result = await ajax(userPath(`${user.username_lower}/invited.json`), {
      data,
    });

    result.invites = trackedArray(result.invites.map((i) => Invite.create(i)));

    return EmberObject.create(result);
  }

  static reinviteAll(
    domain,
    status,
    search,
    { keywords, aiPersonalization, scheduleSend } = {}
  ) {
    const data = {};
    if (!isNone(domain)) {
      data.domain = domain;
    }
    if (!isNone(status)) {
      data.status = status;
    }
    if (!isNone(search)) {
      data.search = search;
    }
    if (!isNone(keywords)) {
      data.keywords = keywords;
    }
    if (!isNone(aiPersonalization)) {
      data.ai_personalization = aiPersonalization;
    }
    if (!isNone(scheduleSend)) {
      data.schedule_send = scheduleSend;
    }
    return ajax("/invites/reinvite-all", { type: "POST", data });
  }

  static destroyAllExpired(user) {
    return ajax("/invites/destroy-all-expired", {
      type: "POST",
      data: { username: user.username },
    });
  }

  static destroyAllInvites(domain, status, search) {
    const data = {};
    if (!isNone(domain)) {
      data.domain = domain;
    }
    if (!isNone(status)) {
      data.status = status;
    }
    if (!isNone(search)) {
      data.search = search;
    }
    return ajax("/invites/destroy-all", { type: "POST", data });
  }

  static findLatestSentEmail(inviteId) {
    return ajax(`/admin/email-logs/invite_sent/${inviteId}.json`);
  }

  // Previews an invite's currently staged (not yet delivered) content --
  // see Admin::EmailLogsController#invite_draft. Only meaningful while
  // draft_preview_available is true (gated server-side to :bulk_pending/
  // :sending, admin-only, same shape as #findLatestSentEmail's response).
  static findDraftPreview(inviteId) {
    return ajax(`/admin/email-logs/invite_draft/${inviteId}.json`);
  }

  // Turns the admin-reviewed CSV text from the "Extract from URL" tab into
  // draft invites (see InvitesController#create_drafts) -- never sent
  // immediately.
  static createDraftsFromCsv(
    csv,
    {
      allowAnyEmail,
      scheduleSend,
      aiPersonalization,
      sourceUrl,
      requestId,
    } = {}
  ) {
    return ajax("/invites/create-drafts", {
      type: "POST",
      data: {
        csv,
        allow_any_email: allowAnyEmail,
        schedule_send: scheduleSend,
        ai_personalization: aiPersonalization,
        source_url: sourceUrl,
        // Lets the server flip this specific UrlExtractionRequest to
        // :closed once its CSV has been acted on -- see
        // InvitesController#create_drafts.
        request_id: requestId,
      },
    });
  }

  // Queues an extraction of {email, name, keywords} rows from one or more
  // pages, sharing the same rules -- one UrlExtractionRequest per URL,
  // each with its own CSV. Runs off-request (see
  // Jobs::ProcessUrlExtractionRequest); each result arrives later via
  // MessageBus, or by loading the Invited page's "Extracted" tab
  // (UsersController#invited, filter: "extracted"), not in this response.
  static submitUrlExtraction(urls, rules) {
    return ajax("/invites/extract-from-url.json", {
      type: "POST",
      data: { urls, rules },
    });
  }

  // Sends (or first-sends, for a draft) every invite in inviteIds, reusing
  // the same resend logic as #reinvite -- see
  // InvitesController#send_drafts.
  static sendDrafts(
    inviteIds,
    { keywords, aiPersonalization, scheduleSend, allowAnyEmail } = {}
  ) {
    return ajax("/invites/send-drafts", {
      type: "POST",
      data: {
        invite_ids: inviteIds,
        keywords,
        ai_personalization: aiPersonalization,
        schedule_send: scheduleSend,
        allow_any_email: allowAnyEmail,
      },
    });
  }

  // Permanently deletes a batch of draft invites -- see
  // InvitesController#destroy_drafts. Unlike #destroy (which soft-trashes a
  // real invite), this hard-deletes since a draft has no send/redemption
  // history worth keeping.
  static destroyDrafts(inviteIds) {
    return ajax("/invites/destroy-drafts", {
      type: "POST",
      data: { invite_ids: inviteIds },
    });
  }

  @computed("topics.firstObject.id")
  get topicId() {
    return this.topics?.firstObject?.id;
  }

  set topicId(value) {
    set(this, "topics.firstObject.id", value);
  }

  @computed("topics.firstObject.title")
  get topicTitle() {
    return this.topics?.firstObject?.title;
  }

  set topicTitle(value) {
    set(this, "topics.firstObject.title", value);
  }

  @computed("invite_key")
  get shortKey() {
    return this.invite_key.slice(0, 4) + "...";
  }

  @computed("groups")
  get groupIds() {
    return this.groups ? this.groups.map((group) => group.id) : [];
  }

  @computed("topics.firstObject")
  get topic() {
    return this.topics?.firstObject
      ? Topic.create(this.topics?.firstObject)
      : null;
  }

  @computed("email", "domain")
  get emailOrDomain() {
    return this.email || this.domain;
  }

  save(data) {
    const promise = this.id
      ? ajax(`/invites/${this.id}`, { type: "PUT", data })
      : ajax("/invites", { type: "POST", data });

    return promise.then((result) => this.setProperties(result));
  }

  destroy() {
    return ajax("/invites", {
      type: "DELETE",
      data: { id: this.id },
    }).then(() => this.set("destroyed", true));
  }

  reinvite({ keywords, aiPersonalization, scheduleSend, allowAnyEmail } = {}) {
    const data = {
      invite_id: this.id,
      keywords,
      ai_personalization: aiPersonalization,
    };
    // Omitted params leave the invite's already-persisted values alone
    // (see InvitesController#resend_overrides_from_params) -- only send
    // them when the caller actually provided one.
    if (!isNone(scheduleSend)) {
      data.schedule_send = scheduleSend;
    }
    if (!isNone(allowAnyEmail)) {
      data.allow_any_email = allowAnyEmail;
    }

    // No .catch here, deliberately -- this is awaited from
    // resend-invite.gjs's own try/catch (which calls popupAjaxError and
    // keeps the modal open on failure), matching Invite.reinviteAll's
    // behavior below. Swallowing the error here would resolve this
    // promise regardless, so the modal would close looking successful
    // even when the resend failed.
    return ajax("/invites/reinvite", { type: "POST", data }).then(() =>
      this.set("reinvited", true)
    );
  }

  // Sends this invite immediately, bypassing Jobs::ProcessBulkInviteEmails'
  // paced queue, and nudges that queue's chain in case it's blocked -- see
  // InvitesController#send_now_invite. No .catch here either, for the same
  // reason as reinvite above: the caller (user-invited/show.js) handles the
  // error itself.
  sendNow() {
    return ajax("/invites/send-now", {
      type: "POST",
      data: { invite_id: this.id },
    }).then((result) => this.set("delivery_status", result.delivery_status));
  }
}
