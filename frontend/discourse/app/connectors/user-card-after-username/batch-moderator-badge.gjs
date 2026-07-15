import Component from "@glimmer/component";
import { showsBatchModeratorBadge } from "discourse/lib/batch-moderator-badge";
import { i18n } from "discourse-i18n";

export default class BatchModeratorBadge extends Component {
  static shouldRender(args) {
    return showsBatchModeratorBadge(args.user);
  }

  <template>
    <span class="user-card-batch-moderator-badge">
      {{i18n "batch_moderation.badge_title"}}
    </span>
  </template>
}
