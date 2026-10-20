import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn, hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import CreateInviteUploader from "discourse/components/create-invite-uploader";
import Form from "discourse/components/form";
import UrlInviteExtractor from "discourse/components/url-invite-extractor";
import GroupChooser from "discourse/select-kit/components/group-chooser";
import TopicChooser from "discourse/select-kit/components/topic-chooser";
import { eq, not } from "discourse/truth-helpers";
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
        @uploader={{uploader}}
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
                    url=""
                    rules=extractor.rules
                    context=""
                    groups=extractor.settingsData.groups
                    topicId=extractor.settingsData.topicId
                    allowAnyEmail=extractor.settingsData.allowAnyEmail
                    scheduleSend=extractor.settingsData.scheduleSend
                    skipPersonalization=extractor.settingsData.skipPersonalization
                  }}
                  @onRegisterApi={{extractor.registerFormApi}}
                  @onSubmit={{extractor.extract}}
                  as |form|
                >
                  <form.Field
                    @name="url"
                    @title={{i18n
                      "user.invited.bulk_invite.url_extraction.url_label"
                    }}
                    @type="input-url"
                    @validation="required|url"
                    as |field|
                  >
                    <field.Control placeholder="https://example.edu/students" />
                  </form.Field>

                  <form.Field
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
                    @description={{i18n
                      "user.invited.bulk_invite.url_extraction.context_description"
                    }}
                    @name="context"
                    @title={{i18n
                      "user.invited.bulk_invite.url_extraction.context_label"
                    }}
                    @type="input"
                    as |field|
                  >
                    <field.Control />
                  </form.Field>

                  <form.Field
                    @name="groups"
                    @title={{i18n
                      "user.invited.bulk_invite.url_extraction.groups_label"
                    }}
                    @type="custom"
                    as |field|
                  >
                    <field.Control>
                      <GroupChooser
                        @content={{extractor.allGroups}}
                        @labelProperty="name"
                        @onChange={{field.set}}
                        @value={{field.value}}
                      />
                    </field.Control>
                  </form.Field>

                  <form.Field
                    @name="topicId"
                    @title={{i18n
                      "user.invited.bulk_invite.url_extraction.topic_label"
                    }}
                    @type="custom"
                    as |field|
                  >
                    <field.Control>
                      <TopicChooser
                        @content={{extractor.topics}}
                        @onChange={{fn extractor.onChangeTopic field.set}}
                        @options={{hash additionalFilters="status:public"}}
                        @value={{field.value}}
                      />
                    </field.Control>
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
                    @name="skipPersonalization"
                    @title={{i18n
                      "user.invited.bulk_invite.url_extraction.skip_personalization_label"
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

                {{#if extractor.rows}}
                  {{#each extractor.warnings as |warning|}}
                    <div class="alert alert-warning">{{warning}}</div>
                  {{/each}}

                  <table class="url-invite-extractor__review-table">
                    <thead>
                      <tr>
                        <th></th>
                        <th>{{i18n
                            "user.invited.bulk_invite.url_extraction.email_column"
                          }}</th>
                        <th>{{i18n
                            "user.invited.bulk_invite.url_extraction.name_column"
                          }}</th>
                      </tr>
                    </thead>
                    <tbody>
                      {{#each extractor.rows key="id" as |row|}}
                        <tr>
                          <td>
                            <input
                              checked={{row.include}}
                              type="checkbox"
                              {{on "click" (fn extractor.toggleRow row)}}
                            />
                          </td>
                          <td>
                            <input
                              type="text"
                              value={{row.email}}
                              {{on "input" (fn extractor.updateRowEmail row)}}
                            />
                          </td>
                          <td>
                            <input
                              type="text"
                              value={{row.name}}
                              {{on "input" (fn extractor.updateRowName row)}}
                            />
                          </td>
                        </tr>
                      {{/each}}
                    </tbody>
                  </table>

                  <div class="url-invite-extractor__review-footer">
                    {{i18n
                      "user.invited.bulk_invite.url_extraction.selected_count"
                      count=extractor.selectedCount
                      total=extractor.rows.length
                    }}
                  </div>
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
              {{else if extractor.rows}}
                <DButton
                  class="btn-primary"
                  @action={{extractor.createInvites}}
                  @disabled={{not extractor.canCreateInvites}}
                  @translatedLabel={{i18n
                    "user.invited.bulk_invite.url_extraction.create_invites_button"
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
