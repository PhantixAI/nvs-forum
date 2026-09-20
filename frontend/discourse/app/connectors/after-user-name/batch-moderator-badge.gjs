import Component from "@glimmer/component";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import { showsBatchModeratorBadge } from "discourse/lib/batch-moderator-badge";
import { i18n } from "discourse-i18n";

export default class BatchModeratorBadge extends Component {
  static shouldRender(args) {
    return showsBatchModeratorBadge(args.user);
  }

  <template>
    <DTooltip
      class="batch-moderator-badge"
      @content={{i18n "batch_moderation.badge_title"}}
      @icon="shield"
      @identifier="batch-moderator-badge"
    />
  </template>
}
