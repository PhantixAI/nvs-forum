import EmberObject, { computed, set } from "@ember/object";
import { trackedArray } from "@ember/reactive/collections";
import { isNone } from "@ember/utils";
import { ajax } from "discourse/lib/ajax";
import { userPath } from "discourse/lib/url";
import Topic, { type TopicFields } from "discourse/models/topic";
import User, { type UserCreateAttrs } from "discourse/models/user";

/** The resolved outcome of InviteMailer's delivery, or `null` when nothing was ever sent. */
export type DeliveryStatus =
  | "review"
  | "drafting"
  | "scheduled"
  | "pending"
  | "skipped"
  | "sent"
  | "complained"
  | "bounced"
  | "delivered";

/** Detail fields are absent for other viewers; redeemed records use a different serializer. */
export interface InviteFields {
  id?: number;
  invite_key?: string;
  link?: string;
  description?: string | null;
  email?: string | null;
  domain?: string | null;
  emailed?: boolean;
  /** Admin-only; gated to invites staged but not yet delivered. */
  draft_preview_available?: boolean;
  delivery_status?: DeliveryStatus | null;
  can_delete_invite?: boolean;
  max_redemptions_allowed?: number;
  redemption_count?: number;
  custom_message?: string | null;
  created_at?: string;
  updated_at?: string;
  expires_at?: string;
  expired?: boolean;
  grants_admin?: boolean;
  grants_moderator?: boolean;
  recipient_keywords?: string | null;
  allow_any_email?: boolean;
  /** The page this invite's recipient/keywords were extracted from, if any. */
  source_url?: string | null;
  /** Server arrays do not supply firstObject; legacy client collections can. */
  topics?: InviteTopic[] & { firstObject?: InviteTopic };
  groups?: { id: number; name: string }[];
  redeemed_at?: string;
  invite_source?: "link" | "email";
  user?: User;
  destroyed?: boolean;
  reinvited?: boolean;
}

export type InviteTopic = Pick<
  TopicFields,
  "id" | "title" | "slug" | "fancy_title" | "posts_count"
>;

/** create wraps the raw redeemed user, but save only merges the response. */
export type InviteCreateAttrs<M = Invite> = Omit<Partial<M>, "user"> & {
  user?: UserCreateAttrs | User;
};

export interface InvitedFields {
  invites: Invite[];
  can_see_invite_details: boolean;
  counts: { pending: number; expired: number; redeemed: number; total: number };
}

export type Invited = EmberObject & InvitedFields;

/** `Invite.createDraftsFromCsv`'s response -- see BulkInviteUrlExtraction::DraftCreator::Result. */
interface CreateDraftsResult {
  created_count: number;
  errors: string[];
}

/** Shared shape of `#findLatestSentEmail`/`#findDraftPreview` -- see EmailLogDetailsSerializer / InviteDraftPreviewSerializer. */
interface SentInviteEmailFields {
  subject: string;
  body: string;
  headers: string;
}

// eslint-disable-next-line @typescript-eslint/no-empty-object-type, @typescript-eslint/no-unsafe-declaration-merging
export default interface Invite extends InviteFields {}

// eslint-disable-next-line @typescript-eslint/no-unsafe-declaration-merging
export default class Invite extends EmberObject {
  static override create<C extends typeof EmberObject>(
    this: C,
    ...args: InviteCreateAttrs<InstanceType<C>>[]
  ): InstanceType<C> {
    const result = super.create(...args) as InstanceType<C> & Invite;
    if (result.user) {
      // TODO(typescript-pending): UserCreateAttrs requires an index signature; remove when User.create accepts model instances.
      result.user = User.create(result.user as UserCreateAttrs);
    }
    return result;
  }

  static async findInvitedBy(
    user?: User | null,
    filter?: string | null,
    search?: string | null,
    offset?: number,
    domain?: string | null,
    status?: string | null
  ): Promise<Invited | undefined> {
    if (!user) {
      return;
    }

    const data: {
      filter?: string;
      search?: string;
      offset?: number;
      domain?: string;
      status?: string;
    } = {};
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

    const result = await ajax<
      Omit<InvitedFields, "invites"> & { invites: InviteCreateAttrs[] }
    >(userPath(`${user.username_lower}/invited.json`), {
      data,
    });

    result.invites = trackedArray(result.invites.map((i) => Invite.create(i)));

    return EmberObject.create(result as Invited);
  }

  static reinviteAll(
    domain?: string | null,
    status?: string | null,
    search?: string | null,
    {
      keywords,
      aiPersonalization,
      scheduleSend,
      sendCount,
      shareable,
      maxUsers,
      shareableDomain,
    }: {
      keywords?: string;
      aiPersonalization?: boolean;
      scheduleSend?: boolean;
      sendCount?: number;
      shareable?: boolean;
      maxUsers?: number;
      shareableDomain?: string;
    } = {}
  ): Promise<unknown> {
    const data: Record<string, unknown> = {};
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
    if (!isNone(sendCount)) {
      data.send_count = sendCount;
    }
    data.shareable = shareable;
    if (shareable) {
      data.max_users = maxUsers;
      data.shareable_domain = shareableDomain;
    }
    return ajax("/invites/reinvite-all", { type: "POST", data });
  }

  static destroyAllExpired(user: User): Promise<unknown> {
    return ajax("/invites/destroy-all-expired", {
      type: "POST",
      data: { username: user.username },
    });
  }

  static destroyAllInvites(
    domain?: string | null,
    status?: string | null,
    search?: string | null
  ): Promise<unknown> {
    const data: { domain?: string; status?: string; search?: string } = {};
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

  static findLatestSentEmail(inviteId: number): Promise<SentInviteEmailFields> {
    return ajax(`/admin/email-logs/invite_sent/${inviteId}.json`);
  }

  // Previews an invite's currently staged (not yet delivered) content --
  // see Admin::EmailLogsController#invite_draft. Only meaningful while
  // draft_preview_available is true (gated server-side to :bulk_pending/
  // :sending, admin-only, same shape as #findLatestSentEmail's response).
  static findDraftPreview(inviteId: number): Promise<SentInviteEmailFields> {
    return ajax(`/admin/email-logs/invite_draft/${inviteId}.json`);
  }

  // Turns the admin-reviewed CSV text from the "Extract from URL" tab into
  // draft invites (see InvitesController#create_drafts) -- never sent
  // immediately.
  static createDraftsFromCsv(
    csv: string,
    {
      allowAnyEmail,
      scheduleSend,
      aiPersonalization,
      sourceUrl,
      requestId,
    }: {
      allowAnyEmail?: boolean;
      scheduleSend?: boolean;
      aiPersonalization?: boolean;
      sourceUrl?: string;
      requestId?: number;
    } = {}
  ): Promise<CreateDraftsResult> {
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
  // draft: true saves the urls without requiring rules yet (see
  // UrlExtractionRequest's :draft status) and never enqueues extraction.
  static submitUrlExtraction(
    urls: string[],
    rules: string,
    { draft }: { draft?: boolean } = {}
  ): Promise<unknown> {
    const data: { urls: string[]; rules: string; draft?: boolean } = {
      urls,
      rules,
    };
    if (draft) {
      data.draft = draft;
    }
    return ajax("/invites/extract-from-url.json", {
      type: "POST",
      data,
    });
  }

  // Hard-deletes a single UrlExtractionRequest -- see
  // InvitesController#destroy_url_extraction_request. Unlike #destroy
  // (which soft-trashes a real invite), this hard-deletes: a request has no
  // send/redemption history worth keeping.
  static destroyUrlExtractionRequest(requestId: number): Promise<unknown> {
    return ajax(`/invites/url-extraction-requests/${requestId}`, {
      type: "DELETE",
    });
  }

  @computed("topics.firstObject.id")
  get topicId() {
    return this.topics?.firstObject?.id;
  }

  set topicId(value: number | undefined) {
    set(this, "topics.firstObject.id", value);
  }

  @computed("topics.firstObject.title")
  get topicTitle() {
    return this.topics?.firstObject?.title;
  }

  set topicTitle(value: string | undefined) {
    set(this, "topics.firstObject.title", value);
  }

  @computed("invite_key")
  /** Requires a detail-visible pending invite with an invite key. */
  get shortKey() {
    return this.invite_key!.slice(0, 4) + "...";
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

  save(data: object) {
    const promise = this.id
      ? ajax<Partial<InviteFields>>(`/invites/${this.id}`, {
          type: "PUT",
          data,
        })
      : ajax<Partial<InviteFields>>("/invites", { type: "POST", data });

    return promise.then((result) => this.setProperties(result));
  }

  /** Deletes the invite remotely rather than scheduling Ember destruction. */
  override destroy(this: never, ...args: never[]): never;
  override destroy(): Promise<boolean>;
  override destroy(): Promise<boolean> {
    return ajax("/invites", {
      type: "DELETE",
      data: { id: this.id },
    }).then(() => this.set("destroyed", true));
  }

  reinvite({
    keywords,
    aiPersonalization,
    scheduleSend,
    allowAnyEmail,
    shareable,
    maxUsers,
    shareableDomain,
  }: {
    keywords?: string;
    aiPersonalization?: boolean;
    scheduleSend?: boolean;
    allowAnyEmail?: boolean;
    shareable?: boolean;
    maxUsers?: number;
    shareableDomain?: string;
  } = {}): Promise<boolean> {
    const data: Record<string, unknown> = {
      invite_id: this.id,
      keywords,
      ai_personalization: aiPersonalization,
      shareable,
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
    if (shareable) {
      data.max_users = maxUsers;
      data.shareable_domain = shareableDomain;
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
  sendNow(): Promise<DeliveryStatus | null> {
    return ajax<{ delivery_status: DeliveryStatus | null }>(
      "/invites/send-now",
      {
        type: "POST",
        data: { invite_id: this.id },
      }
    ).then((result) => this.set("delivery_status", result.delivery_status));
  }

  // Inverse of #sendNow -- pulls a Scheduled invite back out of the send
  // queue instead of pushing it forward. Same shape/error-handling
  // contract: the caller (user-invited/show.js) handles the error itself.
  cancelSchedule(): Promise<DeliveryStatus | null> {
    return ajax<{ delivery_status: DeliveryStatus | null }>(
      "/invites/cancel-schedule",
      {
        type: "POST",
        data: { invite_id: this.id },
      }
    ).then((result) => this.set("delivery_status", result.delivery_status));
  }
}
