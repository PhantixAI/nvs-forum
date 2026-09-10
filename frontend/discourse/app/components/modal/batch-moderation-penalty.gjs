import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { sanitize } from "discourse/lib/text";
import { FORMAT as DATE_INPUT_FORMAT } from "discourse/select-kit/components/future-date-input-selector";
import DButton from "discourse/ui-kit/d-button";
import DFutureDateInput from "discourse/ui-kit/d-future-date-input";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

export default class BatchModerationPenalty extends Component {
  @tracked saving = false;
  @tracked flashText;

  get penaltyType() {
    return this.args.model.penaltyType;
  }

  get user() {
    return this.args.model.user;
  }

  get title() {
    return i18n(`batch_moderation.${this.penaltyType}_title`, {
      username: this.user.username,
    });
  }

  get data() {
    return {
      reason: "",
      until: moment().add(3, "days").format(DATE_INPUT_FORMAT),
    };
  }

  @action
  async onFormSubmit(data) {
    this.saving = true;
    this.flashText = null;

    const path =
      this.penaltyType === "suspend"
        ? `/batch-moderation/users/${this.user.id}/suspend`
        : `/batch-moderation/users/${this.user.id}/silence`;

    const payload = { reason: data.reason };
    if (this.penaltyType === "suspend") {
      payload.suspend_until = data.until;
    } else {
      payload.silenced_till = data.until;
    }

    try {
      await ajax(path, { type: "PUT", data: payload });
      this.args.closeModal();
      if (this.args.model.onPenalize) {
        this.args.model.onPenalize();
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
      class="batch-moderation-penalty-modal"
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
          <form.Field
            @format="full"
            @name="until"
            @title={{i18n "batch_moderation.until"}}
            @type="custom"
            @validation="required"
            as |field|
          >
            <field.Control>
              <DFutureDateInput
                @clearable={{false}}
                @input={{field.value}}
                @noRelativeOptions={{true}}
                @onChangeInput={{field.set}}
              />
            </field.Control>
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
