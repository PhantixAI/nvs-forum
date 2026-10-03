import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { Textarea } from "@ember/component";
import { action } from "@ember/object";
import { popupAjaxError } from "discourse/lib/ajax-error";
import ComboBox from "discourse/select-kit/components/combo-box";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

// Shared by the per-invite "Resend" kebab item and the bulk "Resend
// Invites" button (see user-invited/show.js) -- @model.onResend is the only
// thing that differs between the two call sites.
export default class ResendInviteModal extends Component {
  @tracked aiPersonalization = "true";

  keywords;

  get title() {
    return this.args.model.bulk
      ? i18n("user.invited.resend_invite.modal.title_all")
      : i18n("user.invited.resend_invite.modal.title");
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

  @action
  setAiPersonalization(value) {
    this.aiPersonalization = value;
  }

  @action
  async resend() {
    try {
      await this.args.model.onResend({
        keywords: this.keywords,
        aiPersonalization: this.aiPersonalization,
      });
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
              maxlength="255"
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
              @content={{this.aiPersonalizationOptions}}
              @onChange={{this.setAiPersonalization}}
              @value={{this.aiPersonalization}}
            />
          </div>
        </div>
      </:body>

      <:footer>
        <DButton
          class="btn-primary resend-invite-confirm"
          @action={{this.resend}}
          @icon="paper-plane"
          @label="user.invited.resend_invite.modal.resend"
        />
        <DButton class="cancel" @action={{@closeModal}} @label="cancel" />
      </:footer>
    </DModal>
  </template>
}
