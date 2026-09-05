import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import ComboBox from "discourse/select-kit/components/combo-box";
import { i18n } from "discourse-i18n";

// Matches DiscourseEvents::CalendarSeparation::SEPARATION_FIELD_NAME
export const SEPARATION_FIELD_NAME = "College";
export const ALL_VALUE = "__all__";

// Shared with UpcomingEventsCalendar so the lookup lives in exactly one place.
export function findSeparationField(site) {
  return site.user_fields?.find((f) => f.name === SEPARATION_FIELD_NAME);
}

export default class CalendarSeparationFilter extends Component {
  @service site;

  get separationField() {
    return findSeparationField(this.site);
  }

  get content() {
    const options = this.separationField?.options ?? [];
    return [
      { id: ALL_VALUE, name: this.allLabel },
      ...options.map((option) => ({ id: option, name: option })),
    ];
  }

  get value() {
    return this.args.value ?? ALL_VALUE;
  }

  get allLabel() {
    return i18n("discourse_post_event.upcoming_events.all_colleges");
  }

  @action
  onChange(value) {
    this.args.onChange?.(value);
  }

  <template>
    {{#if this.separationField}}
      <ComboBox
        @content={{this.content}}
        @valueProperty="id"
        @nameProperty="name"
        @value={{this.value}}
        @onChange={{fn this.onChange}}
        class="calendar-separation-filter"
      />
    {{/if}}
  </template>
}
