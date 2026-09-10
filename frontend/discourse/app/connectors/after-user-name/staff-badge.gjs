import Component from "@glimmer/component";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import { i18n } from "discourse-i18n";

export default class StaffBadge extends Component {
  static shouldRender(args) {
    return !!args.user?.is_staff_type;
  }

  <template>
    <DTooltip
      class="staff-badge"
      @content={{i18n "directory.staff_badge_title"}}
      @icon="user-tie"
      @identifier="staff-badge"
    />
  </template>
}
