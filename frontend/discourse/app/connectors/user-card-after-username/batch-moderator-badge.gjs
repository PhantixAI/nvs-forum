import Component from "@glimmer/component";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import { i18n } from "discourse-i18n";

export default class BatchModeratorBadge extends Component {
  static shouldRender(args) {
    return !!args.user?.is_batch_moderator;
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
