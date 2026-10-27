import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { extractError } from "discourse/lib/ajax-error";
import Invite from "discourse/models/invite";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

// Re-submits @model.request's exact url as a brand new UrlExtractionRequest
// (see InvitesController#extract_from_url), letting the admin edit the
// rules first -- the url itself isn't editable here, only the rules. The
// original request is untouched either way: this never retries in place,
// so an edit here can't affect a still-running or already-finished job,
// only the new one it queues.
export default class UrlExtractionRetryModal extends Component {
  @tracked error = null;
  @tracked retrying = false;
  @tracked rules;

  constructor() {
    super(...arguments);
    this.rules = this.args.model.request.rules;
  }

  @action
  async retry() {
    this.error = null;
    this.retrying = true;

    try {
      const result = await Invite.submitUrlExtraction(
        [this.args.model.request.url],
        this.rules
      );
      this.args.model.onRetried(result.requests);
      this.args.closeModal();
    } catch (err) {
      this.error = extractError(err);
    } finally {
      this.retrying = false;
    }
  }

  @action
  updateRules(event) {
    this.rules = event.target.value;
  }

  <template>
    <DModal
      class="url-extraction-retry-modal"
      @closeModal={{@closeModal}}
      @title={{i18n "user.invited.bulk_invite.url_extraction.retry_title"}}
    >
      <:body>
        <div class="url-extraction-retry-modal__url">
          {{@model.request.url}}
        </div>

        <label class="url-extraction-retry-modal__label">
          {{i18n "user.invited.bulk_invite.url_extraction.rules_label"}}
        </label>
        <textarea
          class="url-extraction-retry-modal__textarea"
          rows="8"
          value={{this.rules}}
          {{on "input" this.updateRules}}
        ></textarea>

        {{#if this.error}}
          <div class="alert alert-error">{{this.error}}</div>
        {{/if}}
      </:body>

      <:footer>
        <DButton
          class="btn-primary"
          @action={{this.retry}}
          @disabled={{this.retrying}}
          @translatedLabel={{if
            this.retrying
            (i18n "user.invited.bulk_invite.url_extraction.retrying")
            (i18n "user.invited.bulk_invite.url_extraction.retry_button")
          }}
        />
        <DButton class="btn-primary" @action={{@closeModal}} @label="close" />
      </:footer>
    </DModal>
  </template>
}
