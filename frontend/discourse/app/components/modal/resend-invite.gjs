import Component from "@glimmer/component";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import Form from "discourse/components/form";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { or } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

// Shared by the per-invite "Resend" kebab item, the bulk "Resend Invites"
// button, and the Draft tab's "Send Selected" action (see
// user-invited/show.js) -- @model.onResend is the only thing that differs
// between call sites. @model.drafts additionally surfaces allowAnyEmail,
// which only matters the first time a draft is sent (an ordinary resend's
// bound-vs-unbound shape was already decided when the invite was created).
// scheduleSend is submitted on every resend regardless of @model.bulk/
// @model.drafts (matching resend_all_invites' own default) -- only its
// field is hidden for a plain single resend, where changing it rarely
// makes sense.
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
  async resend({ keywords, aiPersonalization, scheduleSend, allowAnyEmail }) {
    try {
      const payload = { keywords, aiPersonalization, scheduleSend };
      if (this.args.model.drafts) {
        payload.allowAnyEmail = allowAnyEmail;
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
          }}
          @onRegisterApi={{this.registerFormApi}}
          @onSubmit={{this.resend}}
          as |form|
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

          {{#if (or @model.bulk @model.drafts)}}
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
