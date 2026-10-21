import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { ajax } from "discourse/lib/ajax";
import { extractError, popupAjaxError } from "discourse/lib/ajax-error";
import Invite from "discourse/models/invite";

const CSV_HEADER = [
  "email",
  "name",
  "groups",
  "topic_id",
  "locale",
  "keywords",
];

// Not shown in the UI -- there's no per-row control for it today (see
// UrlInviteExtractor's class comment), so it's a fixed default rather than
// a field admins have to think about.
const DEFAULT_LOCALE = "en";

function csvField(value) {
  const text = (value ?? "").toString();
  return /["\n,]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

// Each row's keywords come from the LLM's own per-row extraction (see
// BulkInviteUrlExtraction::Generator#system_message) -- driven by the
// admin's rules (e.g. "use Department, Program, Advisor as keywords"), but
// a per-person value, not the rules text itself repeated on every row.
function buildCsv(rows) {
  const lines = [CSV_HEADER.join(",")];

  rows.forEach((row) => {
    lines.push(
      [row.email, row.name, "", "", DEFAULT_LOCALE, row.keywords]
        .map(csvField)
        .join(",")
    );
  });

  return lines.join("\n");
}

// Renders nothing itself -- owns the URL-extraction state/logic and yields
// it, the same way CreateInviteUploader does, so the caller (the bulk
// invite modal) can render the form fields in its body and the primary
// action button in its footer from one shared, reactive source.
//
// The extracted result is handed to the admin as one editable CSV blob
// (see #extract/#createInvites) rather than a row-by-row table -- the
// admin reviews/edits it directly, then it's submitted as draft invites
// (InvitesController#create_drafts), not sent immediately.
export default class UrlInviteExtractor extends Component {
  @tracked csvText = "";
  @tracked draftErrors = [];
  @tracked draftsCreated = null;
  @tracked creatingDrafts = false;
  @tracked error = null;
  @tracked extracting = false;
  @tracked rules = "";
  @tracked warnings = [];

  // Stable default draft data for the settings toggles that don't vary
  // across renders -- @data's own values are read from here rather than
  // constructed inline (e.g. a fresh object each render), so an admin's
  // already-made selections survive the form's @data hash being
  // recomputed when `rules` arrives asynchronously (see #loadLastRules).
  settingsData = {
    allowAnyEmail: true,
    scheduleSend: true,
    skipPersonalization: false,
  };

  #formApi = null;

  get canCreateInvites() {
    return this.csvHasRows && !this.creatingDrafts;
  }

  // Distinct from a truthy check on draftsCreated -- a result where every
  // row failed is still a result (created_count: 0, errors: [...]), and
  // must still show the error summary instead of falling back to the
  // extraction form.
  get hasDraftResult() {
    return this.draftsCreated !== null;
  }

  get csvHasRows() {
    return this.csvText.split("\n").length > 1;
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
        skipPersonalization: this.#formApi.get("skipPersonalization"),
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
  async extract({ url, rules }) {
    this.error = null;
    this.extracting = true;
    this.csvText = "";

    try {
      const result = await ajax("/invites/extract-from-url.json", {
        type: "POST",
        data: { url, rules },
      });
      this.csvText = buildCsv(result.rows);
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
  registerFormApi(api) {
    this.#formApi = api;
  }

  @action
  submit() {
    this.#formApi.submit();
  }

  @action
  updateCsvText(event) {
    this.csvText = event.target.value;
  }

  <template>
    <div {{didInsert this.loadLastRules}}>
      {{yield
        (hash
          canCreateInvites=this.canCreateInvites
          createInvites=this.createInvites
          creatingDrafts=this.creatingDrafts
          csvText=this.csvText
          draftErrors=this.draftErrors
          draftsCreated=this.draftsCreated
          error=this.error
          extract=this.extract
          extracting=this.extracting
          hasDraftResult=this.hasDraftResult
          registerFormApi=this.registerFormApi
          rules=this.rules
          settingsData=this.settingsData
          submit=this.submit
          updateCsvText=this.updateCsvText
          warnings=this.warnings
        )
      }}
    </div>
  </template>
}
