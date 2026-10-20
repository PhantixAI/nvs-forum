import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { extractError, popupAjaxError } from "discourse/lib/ajax-error";

const CSV_HEADER = [
  "email",
  "groups",
  "topic_id",
  "locale",
  "allow_any_email",
  "schedule_send",
  "skip_personalization",
  "name",
  "keywords",
];

// Not shown in the UI -- there's no per-site reason to vary it today, so it's
// a fixed default rather than a field admins have to think about.
const DEFAULT_LOCALE = "en";

function csvField(value) {
  const text = (value ?? "").toString();
  return /["\n,]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function buildCsv(rows, settings) {
  const groupNames = (settings.groups ?? [])
    .map((group) => group.name)
    .join(";");
  const lines = [CSV_HEADER.join(",")];

  rows
    .filter((row) => row.include)
    .forEach((row) => {
      lines.push(
        [
          row.email,
          groupNames,
          settings.topicId ?? "",
          settings.locale,
          settings.allowAnyEmail ? "true" : "false",
          settings.scheduleSend ? "true" : "false",
          settings.skipPersonalization ? "true" : "false",
          row.name,
          settings.context,
        ]
          .map(csvField)
          .join(",")
      );
    });

  return lines.join("\n");
}

// Renders nothing itself -- owns the URL-extraction state/logic and yields it,
// the same way CreateInviteUploader does, so the caller (the bulk invite
// modal) can render the form fields in its body and the primary action
// button in its footer from one shared, reactive source.
export default class UrlInviteExtractor extends Component {
  @service site;

  @tracked error = null;
  @tracked extracting = false;
  @tracked rows = null;
  @tracked rules = "";
  @tracked topics = [];
  @tracked warnings = [];

  // Stable default draft data for the settings fields that don't vary across
  // renders -- @data's own groups/topicId/etc. values are read from here
  // rather than constructed inline (e.g. a fresh (array) each render), so an
  // admin's already-made selections survive the form's @data hash being
  // recomputed when `rules` arrives asynchronously (see #loadLastRules).
  settingsData = {
    groups: [],
    topicId: null,
    allowAnyEmail: true,
    scheduleSend: true,
    skipPersonalization: false,
  };

  #formApi = null;

  get allGroups() {
    return this.site.groups.filter((group) => !group.automatic);
  }

  get canCreateInvites() {
    return this.selectedCount > 0 && !this.args.uploader.uploading;
  }

  get selectedCount() {
    return (this.rows ?? []).filter((row) => row.include).length;
  }

  @action
  createInvites() {
    const csv = buildCsv(this.rows, {
      allowAnyEmail: this.#formApi.get("allowAnyEmail"),
      context: this.#formApi.get("context"),
      groups: this.#formApi.get("groups"),
      locale: DEFAULT_LOCALE,
      scheduleSend: this.#formApi.get("scheduleSend"),
      skipPersonalization: this.#formApi.get("skipPersonalization"),
      topicId: this.#formApi.get("topicId"),
    });
    const file = new File([csv], "extracted-invites.csv", {
      type: "text/csv",
    });

    this.args.uploader.addFiles(file);
    this.args.uploader.startUpload();
  }

  @action
  async extract({ url, rules, context }) {
    this.error = null;
    this.extracting = true;
    this.rows = null;

    try {
      const result = await ajax("/invites/extract-from-url.json", {
        type: "POST",
        data: { url, rules, context },
      });
      this.rows = result.rows.map((row, index) => ({
        email: row.email,
        id: index,
        include: true,
        name: row.name,
      }));
      this.warnings = result.warnings;
    } catch (err) {
      this.error = extractError(err);
    } finally {
      this.extracting = false;
    }
  }

  @action
  loadLastRules() {
    if (!this.args.enabled) {
      return;
    }

    ajax("/invites/extract-from-url.json")
      .then((result) => (this.rules = result.rules))
      .catch(popupAjaxError);
  }

  @action
  onChangeTopic(fieldSet, topicId, topic) {
    this.topics = [topic];
    fieldSet(topicId);
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
  toggleRow(row) {
    row.include = !row.include;
    this.rows = [...this.rows];
  }

  @action
  updateRowEmail(row, event) {
    row.email = event.target.value;
    this.rows = [...this.rows];
  }

  @action
  updateRowName(row, event) {
    row.name = event.target.value;
    this.rows = [...this.rows];
  }

  <template>
    <div {{didInsert this.loadLastRules}}>
      {{yield
        (hash
          allGroups=this.allGroups
          canCreateInvites=this.canCreateInvites
          createInvites=this.createInvites
          error=this.error
          extract=this.extract
          extracting=this.extracting
          onChangeTopic=this.onChangeTopic
          registerFormApi=this.registerFormApi
          rows=this.rows
          rules=this.rules
          selectedCount=this.selectedCount
          settingsData=this.settingsData
          submit=this.submit
          toggleRow=this.toggleRow
          topics=this.topics
          updateRowEmail=this.updateRowEmail
          updateRowName=this.updateRowName
          warnings=this.warnings
        )
      }}
    </div>
  </template>
}
