import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { extractError, popupAjaxError } from "discourse/lib/ajax-error";
import Invite from "discourse/models/invite";
import { i18n } from "discourse-i18n";

// Renders nothing itself -- owns the URL-extraction submission state/logic
// and yields it, the same way CreateInviteUploader does, so the caller
// (the bulk invite modal) can render the form fields in its body and the
// primary action button in its footer from one shared, reactive source.
//
// Submitting one or more URLs (sharing the same rules/flags) only queues a
// UrlExtractionRequest per URL (see InvitesController#extract_from_url) --
// the actual extraction runs off-request, so an admin can submit several
// URLs, or several batches back-to-back, without waiting on any of them.
// Reviewing a request's extracted CSV and turning it into draft invites
// happens later, from the Invited page's "Extracted" tab (see
// UsersController#invited, filter: "extracted", and
// UrlExtractionReviewModal) -- this component only submits.
export default class UrlInviteExtractor extends Component {
  @service toasts;

  @tracked error = null;
  @tracked extracting = false;
  @tracked savingDraft = false;
  @tracked rules = "";

  #formApi = null;

  @action
  async extract({ urls, rules }) {
    this.error = null;

    const parsedUrls = this.#parseUrls(urls);

    if (!parsedUrls.length) {
      this.error = i18n(
        "user.invited.bulk_invite.url_extraction.urls_required"
      );
      return;
    }

    if (!rules?.trim()) {
      this.error = i18n(
        "user.invited.bulk_invite.url_extraction.rules_required"
      );
      return;
    }

    this.extracting = true;

    try {
      await Invite.submitUrlExtraction(parsedUrls, rules);
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

  // Bypasses the Form's own submit/validation pipeline (reading current
  // values straight off the registered formApi instead) since a draft
  // doesn't need rules -- only #extract's path requires them.
  @action
  async saveDraft() {
    this.error = null;

    const parsedUrls = this.#parseUrls(this.#formApi.get("urls") || "");

    if (!parsedUrls.length) {
      this.error = i18n(
        "user.invited.bulk_invite.url_extraction.urls_required"
      );
      return;
    }

    const rules = this.#formApi.get("rules") || "";
    this.savingDraft = true;

    try {
      await Invite.submitUrlExtraction(parsedUrls, rules, { draft: true });
      this.toasts.success({
        data: {
          message: i18n("user.invited.bulk_invite.url_extraction.draft_saved", {
            count: parsedUrls.length,
          }),
        },
      });
    } catch (err) {
      this.error = extractError(err);
    } finally {
      this.savingDraft = false;
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

  #parseUrls(rawUrls) {
    return rawUrls
      .split("\n")
      .map((url) => url.trim())
      .filter(Boolean);
  }

  <template>
    <div {{didInsert this.loadLastRules}}>
      {{yield
        (hash
          error=this.error
          extract=this.extract
          extracting=this.extracting
          registerFormApi=this.registerFormApi
          rules=this.rules
          saveDraft=this.saveDraft
          savingDraft=this.savingDraft
          submit=this.submit
        )
      }}
    </div>
  </template>
}
