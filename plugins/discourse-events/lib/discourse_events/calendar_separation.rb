# frozen_string_literal: true

module DiscourseEvents
  module CalendarSeparation
    # Hardcoded for the first ship — see plan for the eventual real-settings replacement path.
    SEPARATION_FIELD_NAME = "College"

    # Leading underscore is deliberate and load-bearing: EventCustomFieldsValidator::NAME_FORMAT
    # (/\A[a-z0-9]+.../i) requires custom-field names to *start* with a letter/number, so an admin
    # can never add this literal key to discourse_post_event_allowed_custom_fields — it can only
    # ever be set by this code.
    RESERVED_CUSTOM_FIELD_KEY = "_calendar_separation_value"

    def self.configured_field
      UserField.find_by(name: SEPARATION_FIELD_NAME)
    end

    def self.enabled?
      configured_field.present?
    end

    def self.value_for_user(user)
      return nil if !enabled? || user.nil?
      user.custom_fields["user_field_#{configured_field.id}"].presence
    end
  end
end
