import Component from "@glimmer/component";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import Form from "discourse/components/form";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

// Shared by the per-invite "Resend" kebab item and the bulk "Resend
// Invites"/"Send Invites" button (see user-invited/show.js) --
// @model.onResend is the only thing that differs between call sites.
// "Review" drafts (from a CSV upload or "Extract from URL") are dispatched
// through this exact same bulk path too -- "review" is just another status
// filter on the Pending tab (see InvitesController#resend_all_invites and
// user-invited/show.js's inviteReview), not a separate action. @model.drafts
// additionally surfaces allowAnyEmail, which only matters the first time a
// draft is sent (an ordinary resend's bound-vs-unbound shape was already
// decided when the invite was created). scheduleSend is submitted on every
// resend regardless of which of these modes is active -- its field is
// hidden for a plain single resend (where changing it rarely makes sense)
// and for drafts (sending a batch of drafts should always be paced, never a
// burst, so it isn't a user choice here). The form's seeded default (true)
// is what gets submitted either way the field is hidden. sendAll/sendCount
// (bulk only) let the admin cap a dispatch to the oldest N invites in the
// matched batch instead of all of them. shareable/maxUsers/shareableDomain
// (both single and bulk) convert the invite(s) being sent into a
// multi-redemption link -- see Invite#make_shareable! -- for a group
// mailing-list address that forwards to many real recipients.
export default class ResendInviteModal extends Component {
  #formApi = null;

  get title() {
    return this.args.model.bulk || this.args.model.drafts
      ? i18n("user.invited.resend_invite.modal.title_all")
      : i18n("user.invited.resend_invite.modal.title");
  }

  get confirmLabel() {
    return this.args.model.drafts
      ? "user.invited.resend_invite.modal.send"
      : "user.invited.resend_invite.modal.resend";
  }

  @action
  registerFormApi(api) {
    this.#formApi = api;
  }

  @action
  submit() {
    this.#formApi.submit();
  }

  @action
  async resend({
    keywords,
    aiPersonalization,
    scheduleSend,
    allowAnyEmail,
    sendAll,
    sendCount,
    shareable,
    maxUsers,
    shareableDomain,
  }) {
    try {
      const payload = { keywords, aiPersonalization, scheduleSend };
      if (this.args.model.drafts) {
        payload.allowAnyEmail = allowAnyEmail;
      }
      if (this.args.model.bulk) {
        payload.sendCount = sendAll ? null : sendCount;
      }
      payload.shareable = shareable;
      if (shareable) {
        payload.maxUsers = maxUsers;
        payload.shareableDomain = shareableDomain;
      }
      await this.args.model.onResend(payload);
      this.args.closeModal();
    } catch (error) {
      popupAjaxError(error);
    }
  }

  <template>
    <DModal
      class="resend-invite-modal"
      @closeModal={{@closeModal}}
      @title={{this.title}}
    >
      <:body>
        {{#if @model.confirmMessage}}
          <p>{{@model.confirmMessage}}</p>
        {{/if}}

        <Form
          @data={{hash
            keywords=""
            aiPersonalization=true
            scheduleSend=true
            allowAnyEmail=true
            sendAll=true
            sendCount=null
            shareable=false
            maxUsers=null
            shareableDomain=""
          }}
          @onRegisterApi={{this.registerFormApi}}
          @onSubmit={{this.resend}}
          as |form transientData|
        >
          <form.Field
            @format="full"
            @name="keywords"
            @title={{i18n "user.invited.resend_invite.modal.keywords_label"}}
            @type="textarea"
            as |field|
          >
            <field.Control
              maxlength="100000"
              placeholder={{i18n
                "user.invited.resend_invite.modal.keywords_placeholder"
              }}
            />
          </form.Field>

          <form.Field
            @name="aiPersonalization"
            @title={{i18n
              "user.invited.resend_invite.modal.ai_personalization_label"
            }}
            @type="toggle"
            as |field|
          >
            <field.Control />
          </form.Field>

          <form.Field
            @name="shareable"
            @title={{i18n "user.invited.resend_invite.modal.shareable_label"}}
            @type="toggle"
            as |field|
          >
            <field.Control />
          </form.Field>

          {{#if transientData.shareable}}
            <form.Field
              @name="maxUsers"
              @title={{i18n "user.invited.resend_invite.modal.max_users_label"}}
              @type="input-number"
              @validation="required|integer"
              as |field|
            >
              <field.Control min="1" />
            </form.Field>

            <form.Field
              @name="shareableDomain"
              @title={{i18n
                "user.invited.resend_invite.modal.shareable_domain_label"
              }}
              @type="input"
              as |field|
            >
              <field.Control
                placeholder={{i18n
                  "user.invited.resend_invite.modal.shareable_domain_placeholder"
                }}
              />
            </form.Field>
          {{/if}}

          {{#if @model.bulk}}
            <form.Field
              @name="scheduleSend"
              @title={{i18n
                "user.invited.resend_invite.modal.schedule_send_label"
              }}
              @type="toggle"
              as |field|
            >
              <field.Control />
            </form.Field>

            <form.Field
              @name="sendAll"
              @title={{i18n "user.invited.resend_invite.modal.send_all_label"}}
              @type="toggle"
              as |field|
            >
              <field.Control />
            </form.Field>

            {{#unless transientData.sendAll}}
              <form.Field
                @name="sendCount"
                @title={{i18n
                  "user.invited.resend_invite.modal.send_count_label"
                }}
                @type="input-number"
                @validation="required|integer"
                as |field|
              >
                <field.Control min="1" />
              </form.Field>
            {{/unless}}
          {{/if}}

          {{#if @model.drafts}}
            <form.Field
              @name="allowAnyEmail"
              @title={{i18n
                "user.invited.resend_invite.modal.allow_any_email_label"
              }}
              @type="toggle"
              as |field|
            >
              <field.Control />
            </form.Field>
          {{/if}}
        </Form>
      </:body>

      <:footer>
        <DButton
          class="btn-primary resend-invite-confirm"
          @action={{this.submit}}
          @icon="paper-plane"
          @label={{this.confirmLabel}}
        />
        <DButton class="cancel" @action={{@closeModal}} @label="cancel" />
      </:footer>
    </DModal>
  </template>
}
