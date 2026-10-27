import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import Form from "discourse/components/form";
import { extractError } from "discourse/lib/ajax-error";
import Invite from "discourse/models/invite";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

// Reviews a single UrlExtractionRequest's extracted CSV (see
// UsersController#invited, filter: "extracted") and turns it into draft
// invites -- the same Invite.createDraftsFromCsv call the old inline
// "Extract from URL" review step used, just opened independently later
// from the Invited page's Extracted tab rather than right after
// submission. allowAnyEmail/scheduleSend/aiPersonalization aren't stored
// on the request itself, so this modal captures them fresh at review time.
export default class UrlExtractionReviewModal extends Component {
  @tracked creatingDrafts = false;
  @tracked csvText = this.args.model.csv_text ?? "";
  @tracked draftErrors = [];
  @tracked draftsCreated = null;
  @tracked error = null;

  #formApi = null;

  get canCreateInvites() {
    return this.csvHasRows && !this.creatingDrafts;
  }

  get csvHasRows() {
    return this.csvText.split("\n").length > 1;
  }

  // Distinct from a truthy check on draftsCreated -- a result where every
  // row failed is still a result (created_count: 0, errors: [...]), and
  // must still show the error summary instead of the review form.
  get hasDraftResult() {
    return this.draftsCreated !== null;
  }

  @action
  async createInvites() {
    this.creatingDrafts = true;
    this.draftsCreated = null;
    this.draftErrors = [];

    try {
      const result = await Invite.createDraftsFromCsv(this.csvText, {
        allowAnyEmail: this.#formApi.get("allowAnyEmail"),
        scheduleSend: this.#formApi.get("scheduleSend"),
        aiPersonalization: this.#formApi.get("aiPersonalization"),
        sourceUrl: this.args.model.url,
        requestId: this.args.model.id,
      });
      this.draftsCreated = result.created_count;
      this.draftErrors = result.errors;
    } catch (err) {
      this.error = extractError(err);
    } finally {
      this.creatingDrafts = false;
    }
  }

  @action
  registerFormApi(api) {
    this.#formApi = api;
  }

  @action
  updateCsvText(event) {
    this.csvText = event.target.value;
  }

  <template>
    <DModal
      class="url-extraction-review-modal"
      @closeModal={{@closeModal}}
      @title={{i18n "user.invited.bulk_invite.url_extraction.csv_review_label"}}
    >
      <:body>
        {{#if this.hasDraftResult}}
          {{i18n
            "user.invited.bulk_invite.url_extraction.drafts_created"
            count=this.draftsCreated
          }}
          {{#each this.draftErrors as |draftError|}}
            <div class="alert alert-warning">{{draftError}}</div>
          {{/each}}
        {{else}}
          {{#each @model.warnings as |warning|}}
            <div class="alert alert-warning">{{warning}}</div>
          {{/each}}

          <textarea
            class="url-extraction-review-modal__textarea"
            rows="12"
            value={{this.csvText}}
            {{on "input" this.updateCsvText}}
          ></textarea>

          <Form
            @data={{hash
              allowAnyEmail=true
              scheduleSend=true
              aiPersonalization=true
            }}
            @onRegisterApi={{this.registerFormApi}}
            as |form|
          >
            <form.Field
              @name="allowAnyEmail"
              @title={{i18n
                "user.invited.bulk_invite.url_extraction.allow_any_email_label"
              }}
              @type="toggle"
              as |field|
            >
              <field.Control />
            </form.Field>

            <form.Field
              @name="scheduleSend"
              @title={{i18n
                "user.invited.bulk_invite.url_extraction.schedule_send_label"
              }}
              @type="toggle"
              as |field|
            >
              <field.Control />
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
          </Form>

          {{#if this.error}}
            <div class="alert alert-error">{{this.error}}</div>
          {{/if}}
        {{/if}}
      </:body>

      <:footer>
        {{#unless this.hasDraftResult}}
          <DButton
            class="btn-primary"
            @action={{this.createInvites}}
            @disabled={{not this.canCreateInvites}}
            @translatedLabel={{if
              this.creatingDrafts
              (i18n "user.invited.bulk_invite.url_extraction.creating_invites")
              (i18n
                "user.invited.bulk_invite.url_extraction.create_invites_button"
              )
            }}
          />
        {{/unless}}
        <DButton class="btn-primary" @action={{@closeModal}} @label="close" />
      </:footer>
    </DModal>
  </template>
}
