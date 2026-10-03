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

  reinvite({ keywords, aiPersonalization } = {}) {
    // No .catch here, deliberately -- this is awaited from
    // resend-invite.gjs's own try/catch (which calls popupAjaxError and
    // keeps the modal open on failure), matching Invite.reinviteAll's
    // behavior below. Swallowing the error here would resolve this
    // promise regardless, so the modal would close looking successful
    // even when the resend failed.
    return ajax("/invites/reinvite", {
      type: "POST",
      data: {
        invite_id: this.id,
        keywords,
        ai_personalization: aiPersonalization,
      },
    }).then(() => this.set("reinvited", true));
  }
}
