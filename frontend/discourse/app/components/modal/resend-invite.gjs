import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { Textarea } from "@ember/component";
import { action } from "@ember/object";
import { popupAjaxError } from "discourse/lib/ajax-error";
import ComboBox from "discourse/select-kit/components/combo-box";
import { or } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

// Shared by the per-invite "Resend" kebab item, the bulk "Resend Invites"
// button, and the Draft tab's "Send Selected" action (see
// user-invited/show.js) -- @model.onResend is the only thing that differs
// between call sites. @model.drafts additionally surfaces allowAnyEmail/
// skipPersonalization, which only matter the first time a draft is sent
// (an ordinary resend's bound-vs-unbound shape and personalization default
// were already decided when the invite was created).
export default class ResendInviteModal extends Component {
  @tracked aiPersonalization = "true";
  @tracked scheduleSend = "true";
  @tracked allowAnyEmail = "true";
  @tracked skipPersonalization = "false";

  keywords;

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

  get aiPersonalizationOptions() {
    return [
      {
        id: "true",
        name: i18n("user.invited.resend_invite.modal.ai_personalization_yes"),
      },
      {
        id: "false",
        name: i18n("user.invited.resend_invite.modal.ai_personalization_no"),
      },
    ];
  }

  get scheduleSendOptions() {
    return [
      {
        id: "true",
        name: i18n("user.invited.resend_invite.modal.schedule_send_yes"),
      },
      {
        id: "false",
        name: i18n("user.invited.resend_invite.modal.schedule_send_no"),
      },
    ];
  }

  get allowAnyEmailOptions() {
    return [
      {
        id: "true",
        name: i18n("user.invited.resend_invite.modal.allow_any_email_yes"),
      },
      {
        id: "false",
        name: i18n("user.invited.resend_invite.modal.allow_any_email_no"),
      },
    ];
  }

  get skipPersonalizationOptions() {
    return [
      {
        id: "true",
        name: i18n("user.invited.resend_invite.modal.skip_personalization_yes"),
      },
      {
        id: "false",
        name: i18n("user.invited.resend_invite.modal.skip_personalization_no"),
      },
    ];
  }

  @action
  setAiPersonalization(value) {
    this.aiPersonalization = value;
  }

  @action
  setScheduleSend(value) {
    this.scheduleSend = value;
  }

  @action
  setAllowAnyEmail(value) {
    this.allowAnyEmail = value;
  }

  @action
  setSkipPersonalization(value) {
    this.skipPersonalization = value;
  }

  @action
  async resend() {
    try {
      const payload = {
        keywords: this.keywords,
        aiPersonalization: this.aiPersonalization,
        scheduleSend: this.scheduleSend,
      };
      if (this.args.model.drafts) {
        payload.allowAnyEmail = this.allowAnyEmail;
        payload.skipPersonalization = this.skipPersonalization;
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

        <div class="control-group">
          <label>{{i18n
              "user.invited.resend_invite.modal.keywords_label"
            }}</label>
          <div class="controls">
            <Textarea
              maxlength="100000"
              placeholder={{i18n
                "user.invited.resend_invite.modal.keywords_placeholder"
              }}
              @value={{this.keywords}}
            />
          </div>
        </div>

        <div class="control-group">
          <label>{{i18n
              "user.invited.resend_invite.modal.ai_personalization_label"
            }}</label>
          <div class="controls">
            <ComboBox
              class="resend-invite-ai-personalization"
              @content={{this.aiPersonalizationOptions}}
              @onChange={{this.setAiPersonalization}}
              @value={{this.aiPersonalization}}
            />
          </div>
        </div>

        {{#if (or @model.bulk @model.drafts)}}
          <div class="control-group">
            <label>{{i18n
                "user.invited.resend_invite.modal.schedule_send_label"
              }}</label>
            <div class="controls">
              <ComboBox
                class="resend-invite-schedule-send"
                @content={{this.scheduleSendOptions}}
                @onChange={{this.setScheduleSend}}
                @value={{this.scheduleSend}}
              />
            </div>
          </div>
        {{/if}}

        {{#if @model.drafts}}
          <div class="control-group">
            <label>{{i18n
                "user.invited.resend_invite.modal.allow_any_email_label"
              }}</label>
            <div class="controls">
              <ComboBox
                class="resend-invite-allow-any-email"
                @content={{this.allowAnyEmailOptions}}
                @onChange={{this.setAllowAnyEmail}}
                @value={{this.allowAnyEmail}}
              />
            </div>
          </div>

          <div class="control-group">
            <label>{{i18n
                "user.invited.resend_invite.modal.skip_personalization_label"
              }}</label>
            <div class="controls">
              <ComboBox
                class="resend-invite-skip-personalization"
                @content={{this.skipPersonalizationOptions}}
                @onChange={{this.setSkipPersonalization}}
                @value={{this.skipPersonalization}}
              />
            </div>
          </div>
        {{/if}}
      </:body>

      <:footer>
        <DButton
          class="btn-primary resend-invite-confirm"
          @action={{this.resend}}
          @icon="paper-plane"
          @label={{this.confirmLabel}}
        />
        <DButton class="cancel" @action={{@closeModal}} @label="cancel" />
      </:footer>
    </DModal>
  </template>
}
