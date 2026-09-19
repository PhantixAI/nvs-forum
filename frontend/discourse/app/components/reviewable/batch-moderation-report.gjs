import ReviewableCreatedBy from "discourse/components/reviewable-created-by";
import DUserLink from "discourse/ui-kit/d-user-link";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";
import { i18n } from "discourse-i18n";

export default <template>
  <div class="review-item__meta-content">
    <div class="review-item__meta-label">{{i18n
        "batch_moderation.reviewable.reported_by"
      }}</div>
    <div class="review-item__meta-flagged-user">
      <ReviewableCreatedBy
        @showUsername={{true}}
        @user={{@reviewable.created_by}}
      />
    </div>

    <div class="review-item__meta-label">{{i18n
        "batch_moderation.reviewable.reported_user"
      }}</div>
    <div class="review-item__meta-flagged-user">
      {{#if @reviewable.target_user}}
        <DUserLink @user={{@reviewable.target_user}}>
          {{dAvatar @reviewable.target_user imageSize="large"}}
          <span class="username">{{@reviewable.target_user.username}}</span>
        </DUserLink>
      {{/if}}
    </div>
  </div>

  <div class="review-item__post">
    {{#if @reviewable.payload.reports.length}}
      <div class="review-item__meta-label">{{i18n
          "batch_moderation.reviewable.all_reports"
        }}</div>
      <ul class="batch-moderation-report__reports">
        {{#each @reviewable.payload.reports as |report|}}
          <li class="batch-moderation-report__report">
            <span
              class="batch-moderation-report__reporter"
            >{{report.reporter_username}}:</span>
            {{report.reason}}
          </li>
        {{/each}}
      </ul>
    {{else}}
      <p>{{@reviewable.payload.reason}}</p>
    {{/if}}
  </div>
</template>
