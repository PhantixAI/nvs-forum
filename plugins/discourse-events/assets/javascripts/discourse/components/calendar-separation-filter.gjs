import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import ComboBox from "discourse/select-kit/components/combo-box";
import { i18n } from "discourse-i18n";

export const ALL_VALUE = "__all__";

// Shared with UpcomingEventsCalendar so the lookup lives in exactly one place.
// The institution field name (College, Vidyalaya, ...) is resolved server-side --
// see DiscourseEvents::CalendarEventScope.institution_field -- and served via the
// `:site` serializer, so this never drifts from the actual configured site setting.
export function findSeparationField(site) {
  const fieldName = site.calendar_event_scope_fields?.institution_field_name;
  if (!fieldName) {
    return null;
  }
  return site.user_fields?.find((f) => f.name === fieldName);
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
        class="calendar-separation-filter"
        @content={{this.content}}
        @nameProperty="name"
        @onChange={{fn this.onChange}}
        @value={{this.value}}
        @valueProperty="id"
      />
    {{/if}}
  </template>
}
