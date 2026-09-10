import Component from "@glimmer/component";
import { trustHTML } from "@ember/template";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

export default class DToggleSwitch extends Component {
  get computedLabel() {
    if (this.args.label) {
      return i18n(this.args.label);
    }
    return this.args.translatedLabel;
  }

  get computedInsideLabel() {
    if (this.args.insideLabel) {
      return i18n(this.args.insideLabel);
    }
    return this.args.translatedInsideLabel;
  }

  // The track has no intrinsic width for its text -- widen it per-instance
  // based on the label's actual (possibly translated) length, rather than a
  // single fixed size that only fits one word. A plain per-character `ch`
  // unit overestimates width for this bold, condensed label font (e.g. it
  // reserved ~76px for "Staff", which only needs ~58px) -- a smaller
  // fixed pixel-per-character estimate tracks the real rendered width more
  // closely while still scaling for other label lengths.
  get insideLabelStyle() {
    const label = this.computedInsideLabel;
    if (!label) {
      return;
    }
    return trustHTML(
      `--toggle-switch-width: calc(24px + ${label.length * 7}px)`
    );
  }

  <template>
    <div
      class={{dConcatClass
        "d-toggle-switch"
        (if this.computedInsideLabel "--has-inside-label")
      }}
      style={{this.insideLabelStyle}}
    >
      <label class="d-toggle-switch__label">
        <button
          aria-checked={{if @state "true" "false"}}
          class="d-toggle-switch__checkbox"
          role="switch"
          type="button"
          ...attributes
        ></button>

        <span class="d-toggle-switch__checkbox-slider">
          {{#if this.computedInsideLabel}}
            {{! Always visible, unlike the checkmark below -- the knob
              sliding to the opposite side (see the CSS) and the track's
              background color are what communicate on/off here, not
              whether the text itself is showing. }}
            <span class="d-toggle-switch__inside-label">
              {{this.computedInsideLabel}}
            </span>
          {{else if @state}}
            {{dIcon "check"}}
          {{/if}}
        </span>
      </label>

      {{#if @icon}}
        {{! Always rendered (unlike the text label), styled active/inactive
          via @state -- an icon-only indicator of what the toggle represents,
          rather than a word. A floating DTooltip (not a native title
          attribute) carries the label, matching the rest of the app's
          tooltip convention. }}
        <DTooltip
          class={{dConcatClass
            "d-toggle-switch__icon-label"
            (if @state "--active")
          }}
          @content={{this.computedLabel}}
          @icon={{@icon}}
          @identifier="d-toggle-switch-icon"
        />
      {{else if this.computedLabel}}
        <span class="d-toggle-switch__checkbox-label">
          {{this.computedLabel}}
        </span>
      {{/if}}
    </div>
  </template>
}
