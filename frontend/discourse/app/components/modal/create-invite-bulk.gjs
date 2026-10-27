import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import CreateInviteUploader from "discourse/components/create-invite-uploader";
import Form from "discourse/components/form";
import UrlInviteExtractor from "discourse/components/url-invite-extractor";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

export default class CreateInviteBulk extends Component {
  @service siteSettings;

  @tracked activeTab = "csv";

  @action
  showCsvTab() {
    this.activeTab = "csv";
  }

  @action
  showUrlTab() {
    this.activeTab = "url";
  }

  <template>
    <CreateInviteUploader @autoFindInput={{false}} as |uploader setElement|>
      <UrlInviteExtractor
        @enabled={{this.siteSettings.bulk_invite_url_extraction_enabled}}
        as |extractor|
      >
        <DModal
          class="create-invite-bulk-modal --large"
          @closeModal={{@closeModal}}
          @title={{i18n "user.invited.bulk_invite.text"}}
        >
          <:body>
            {{#if uploader.uploaded}}
              {{#if uploader.pendingReview}}
                {{i18n "user.invited.bulk_invite.pending_review"}}
              {{else}}
                {{i18n "user.invited.bulk_invite.success"}}
              {{/if}}
            {{else}}
              {{#if this.siteSettings.bulk_invite_url_extraction_enabled}}
                <div class="create-invite-bulk-modal__tabs">
                  <DButton
                    class={{if
                      (eq this.activeTab "csv")
                      "btn-primary"
                      "btn-default"
                    }}
                    @action={{this.showCsvTab}}
                    @label="user.invited.bulk_invite.url_extraction.csv_tab"
                  />
                  <DButton
                    class={{if
                      (eq this.activeTab "url")
                      "btn-primary"
                      "btn-default"
                    }}
                    @action={{this.showUrlTab}}
                    @label="user.invited.bulk_invite.url_extraction.url_tab"
                  />
                </div>
              {{/if}}

              {{#if (eq this.activeTab "csv")}}
                {{trustHTML (i18n "user.invited.bulk_invite.instructions")}}
                <input
                  accept=".csv"
                  disabled={{uploader.uploading}}
                  id="csv-file"
                  type="file"
                  {{didInsert setElement}}
                />
              {{else}}
                <Form
                  class="url-invite-extractor__form"
                  @data={{hash
                    urls=""
                    rules=extractor.rules
                    allowAnyEmail=true
                    scheduleSend=true
                    aiPersonalization=true
                  }}
                  @onRegisterApi={{extractor.registerFormApi}}
                  @onSubmit={{extractor.extract}}
                  as |form|
                >
                  <form.Field
                    @format="full"
                    @helpText={{i18n
                      "user.invited.bulk_invite.url_extraction.urls_help"
                    }}
                    @name="urls"
                    @title={{i18n
                      "user.invited.bulk_invite.url_extraction.urls_label"
                    }}
                    @type="textarea"
                    @validation="required"
                    as |field|
                  >
                    <field.Control
                      placeholder="https://example.edu/students
https://example.edu/alumni"
                      @height={{80}}
                    />
                  </form.Field>

                  <form.Field
                    @format="full"
                    @name="rules"
                    @title={{i18n
                      "user.invited.bulk_invite.url_extraction.rules_label"
                    }}
                    @type="textarea"
                    @validation="required"
                    as |field|
                  >
                    <field.Control @height={{120}} />
                  </form.Field>

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

                {{#if extractor.error}}
                  <div class="alert alert-error">{{extractor.error}}</div>
                {{/if}}
              {{/if}}
            {{/if}}
          </:body>
          <:footer>
            {{#unless uploader.uploaded}}
              {{#if (eq this.activeTab "csv")}}
                <DButton
                  class="btn-primary"
                  @action={{uploader.startUpload}}
                  @disabled={{uploader.submitDisabled}}
                  @icon="link"
                  @translatedLabel={{if
                    uploader.uploading
                    (i18n
                      "user.invited.bulk_invite.progress"
                      progress=uploader.uploadProgress
                    )
                    (i18n "user.invited.bulk_invite.text")
                  }}
                />
              {{else}}
                <DButton
                  class="btn-primary"
                  @action={{extractor.submit}}
                  @disabled={{extractor.extracting}}
                  @translatedLabel={{if
                    extractor.extracting
                    (i18n "user.invited.bulk_invite.url_extraction.extracting")
                    (i18n
                      "user.invited.bulk_invite.url_extraction.extract_button"
                    )
                  }}
                />
              {{/if}}
            {{/unless}}
            <DButton
              class="btn-primary"
              @action={{@closeModal}}
              @label="close"
            />
          </:footer>
        </DModal>
      </UrlInviteExtractor>
    </CreateInviteUploader>
  </template>
}
