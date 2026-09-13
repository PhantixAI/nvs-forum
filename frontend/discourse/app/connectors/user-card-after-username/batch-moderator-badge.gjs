import Component from "@glimmer/component";
import { i18n } from "discourse-i18n";

export default class BatchModeratorBadge extends Component {
  static shouldRender(args) {
    return !!args.user?.is_batch_moderator;
  }

  <template>
    <span class="user-card-batch-moderator-badge">
      {{i18n "batch_moderation.badge_title"}}
    </span>
  </template>
}
