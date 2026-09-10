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
    <p>{{@reviewable.payload.reason}}</p>
  </div>
</template>
