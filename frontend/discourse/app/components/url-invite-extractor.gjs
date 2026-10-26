import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { extractError, popupAjaxError } from "discourse/lib/ajax-error";
import { bind } from "discourse/lib/decorators";
import Invite from "discourse/models/invite";
import { i18n } from "discourse-i18n";

// Matches Jobs::ProcessUrlExtractionRequest::CHANNEL -- published once an
// extraction request finishes (ready or failed), targeted at the admin who
// submitted it.
const PROGRESS_CHANNEL = "/url-extraction-progress";

// Renders nothing itself -- owns the URL-extraction state/logic and yields
// it, the same way CreateInviteUploader does, so the caller (the bulk
// invite modal) can render the form fields in its body and the primary
// action button in its footer from one shared, reactive source.
//
// Submitting one or more URLs (sharing the same rules/flags) only queues a
// UrlExtractionRequest per URL (see InvitesController#extract_from_url) --
// the actual extraction runs off-request, so an admin can submit several
// URLs, or several batches back-to-back, without waiting on any of them.
// #requests tracks them all; #onProgress keeps that list (and the
// currently open request) live as each one finishes. Each request's
// extracted result is handed to the admin as its own editable CSV blob
// (see #openRequest/#createInvites) rather than a row-by-row table -- the
// admin reviews/edits it directly, then it's submitted as draft invites
// (InvitesController#create_drafts), not sent immediately.
export default class UrlInviteExtractor extends Component {
  @service messageBus;
  @service toasts;

  @tracked csvText = "";
  @tracked draftErrors = [];
  @tracked draftsCreated = null;
  @tracked creatingDrafts = false;
  @tracked error = null;
  @tracked extracting = false;
  @tracked requests = [];
  @tracked rules = "";
  @tracked selectedRequest = null;
  @tracked warnings = [];

  // Stable default draft data for the settings toggles that don't vary
  // across renders -- @data's own values are read from here rather than
  // constructed inline (e.g. a fresh object each render), so an admin's
  // already-made selections survive the form's @data hash being
  // recomputed when `rules` arrives asynchronously (see #loadLastRules).
  settingsData = {
    allowAnyEmail: true,
    scheduleSend: true,
    aiPersonalization: true,
  };

  #formApi = null;

  constructor() {
    super(...arguments);
    this.messageBus.subscribe(PROGRESS_CHANNEL, this.onProgress);
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.messageBus.unsubscribe(PROGRESS_CHANNEL, this.onProgress);
  }

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
        aiPersonalization: this.#formApi.get("aiPersonalization"),
        sourceUrl: this.selectedRequest?.url,
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
  async extract({ urls, rules }) {
    this.error = null;

    const parsedUrls = urls
      .split("\n")
      .map((url) => url.trim())
      .filter(Boolean);

    if (!parsedUrls.length) {
      this.error = i18n(
        "user.invited.bulk_invite.url_extraction.urls_required"
      );
      return;
    }

    this.extracting = true;

    try {
      const result = await Invite.submitUrlExtraction(parsedUrls, rules);
      this.requests = [...result.requests, ...this.requests];
      this.toasts.success({
        data: {
          message: i18n("user.invited.bulk_invite.url_extraction.submitted", {
            count: parsedUrls.length,
          }),
        },
      });
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
  loadRequests() {
    if (!this.args.enabled) {
      return;
    }

    Invite.fetchUrlExtractionRequests()
      .then((result) => (this.requests = result.requests))
      .catch(popupAjaxError);
  }

  @bind
  onProgress(data) {
    const updated = data.request;
    this.requests = this.requests.map((request) =>
      request.id === updated.id ? updated : request
    );

    if (this.selectedRequest?.id === updated.id) {
      this.openRequest(updated);
    }
  }

  @action
  openRequest(request) {
    this.selectedRequest = request;
    this.csvText = request.csv_text ?? "";
    this.warnings = request.warnings ?? [];
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
    <div {{didInsert this.loadLastRules}} {{didInsert this.loadRequests}}>
      {{yield
        (hash
          canCreateInvites=this.canCreateInvites
          createInvites=this.createInvites
          creatingDrafts=this.creatingDrafts
          csvText=this.csvText
          draftErrors=this.draftErrors
          error=this.error
          extract=this.extract
          extracting=this.extracting
          hasDraftResult=this.hasDraftResult
          openRequest=this.openRequest
          registerFormApi=this.registerFormApi
          requests=this.requests
          rules=this.rules
          selectedRequest=this.selectedRequest
          settingsData=this.settingsData
          submit=this.submit
          updateCsvText=this.updateCsvText
          warnings=this.warnings
        )
      }}
    </div>
  </template>
}
