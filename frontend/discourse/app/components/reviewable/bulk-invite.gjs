import Component from "@glimmer/component";
import { action } from "@ember/object";
import ReviewableCreatedBy from "discourse/components/reviewable-created-by";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

export default class ReviewableBulkInvite extends Component {
  get inviteCount() {
    return this.args.reviewable.payload?.invites?.length || 0;
  }

  @action
  downloadCsv() {
    const blob = new Blob([this.args.reviewable.payload.raw_csv], {
      type: "text/csv",
    });
    const url = URL.createObjectURL(blob);

    const link = document.createElement("a");
    link.href = url;
    link.download = `bulk-invite-${this.args.reviewable.id}.csv`;
    link.click();

    URL.revokeObjectURL(url);
  }

  <template>
    <div class="review-item__meta-content">
      <div class="review-item__meta-label">{{i18n
          "batch_moderation.reviewable_bulk_invite.submitted_by"
        }}</div>
      <div class="review-item__meta-flagged-user">
        <ReviewableCreatedBy
          @showUsername={{true}}
          @user={{@reviewable.created_by}}
        />
      </div>
    </div>

    <div class="review-item__post reviewable-bulk-invite">
      <p>
        {{i18n
          "batch_moderation.reviewable_bulk_invite.invite_count"
          count=this.inviteCount
        }}
        <DButton
          class="btn-default reviewable-bulk-invite__download"
          @action={{this.downloadCsv}}
          @icon="download"
          @label="batch_moderation.reviewable_bulk_invite.download"
        />
      </p>
      {{! Rendered verbatim from the uploaded file rather than reconstructed
        from the parsed invites, which drop any column left blank on every
        row -- this is what was actually uploaded, byte for byte. }}
      <pre
        class="reviewable-bulk-invite__raw-csv"
      >{{@reviewable.payload.raw_csv}}</pre>
    </div>
  </template>
}
