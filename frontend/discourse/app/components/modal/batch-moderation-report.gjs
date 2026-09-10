import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { sanitize } from "discourse/lib/text";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

export default class BatchModerationReport extends Component {
  @tracked saving = false;
  @tracked flashText;

  get user() {
    return this.args.model.user;
  }

  get title() {
    return i18n("batch_moderation.report_title", {
      username: this.user.username,
    });
  }

  get data() {
    return { reason: "" };
  }

  @action
  async onFormSubmit(data) {
    this.saving = true;
    this.flashText = null;

    try {
      await ajax(`/batch-moderation/users/${this.user.id}/report`, {
        type: "PUT",
        data: { reason: data.reason },
      });
      this.args.closeModal();
      if (this.args.model.onReport) {
        this.args.model.onReport();
      }
    } catch (error) {
      this.flashText = sanitize(extractError(error));
    } finally {
      this.saving = false;
    }
  }

  @action
  registerApi(api) {
    this.formApi = api;
  }

  @action
  submit() {
    this.formApi.submit();
  }

  <template>
    <DModal
      class="batch-moderation-report-modal"
      @closeModal={{@closeModal}}
      @title={{this.title}}
    >
      <:body>
        {{#if this.flashText}}
          <div class="alert alert-error" role="alert">{{this.flashText}}</div>
        {{/if}}
        <Form
          @data={{this.data}}
          @onRegisterApi={{this.registerApi}}
          @onSubmit={{this.onFormSubmit}}
          as |form|
        >
          <form.Field
            @format="full"
            @name="reason"
            @title={{i18n "batch_moderation.reason"}}
            @type="textarea"
            @validation="required"
            as |field|
          >
            <field.Control
              placeholder={{i18n "batch_moderation.reason_placeholder"}}
            />
          </form.Field>
        </Form>
      </:body>
      <:footer>
        <DButton
          class="btn-primary batch-moderation-submit"
          @action={{this.submit}}
          @disabled={{this.saving}}
          @label="batch_moderation.submit"
        />
        <DButton
          class="btn-transparent cancel-button"
          @action={{@closeModal}}
          @label="batch_moderation.cancel"
        />
      </:footer>
    </DModal>
  </template>
}
