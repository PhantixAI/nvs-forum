# frozen_string_literal: true

module DiscourseEvents
  module CalendarEventScope
    # Same leading-underscore rationale as CalendarSeparation::RESERVED_CUSTOM_FIELD_KEY --
    # these can never be set by a client directly, only by this plugin's sync code.
    SCOPE_CUSTOM_FIELD_KEY = "_calendar_event_scope"
    COHORT_DIGEST_CUSTOM_FIELD_KEY = "_calendar_batch_cohort_digest"

    BATCH = "batch"
    COLLEGE = "college"
    FORUM = "forum"
    VALUES = [BATCH, COLLEGE, FORUM].freeze

    def self.institution_field
      BatchModeration::GroupSync.find_institution_field
    end

    def self.batch_field
      UserField.find_by(name: SiteSetting.batch_moderation_batch_field_name)
    end

    def self.institution_value_for(user)
      field = institution_field
      return nil if !field || user.nil?
      user.custom_fields["#{User::USER_FIELD_PREFIX}#{field.id}"].presence
    end

    # A 12-char digest of the user's full batch+branch cohort, or `nil` if
    # their cohort isn't fully resolvable (missing batch value), or for a
    # staff-type user, whose cohort key is institution-only (see
    # BatchModeration::GroupSync.cohort_key_for) -- an institution-only key
    # carries no batch/branch distinction at all, so it's not a meaningful
    # "batch cohort" (it would be indistinguishable from every other staff
    # member's key at this same institution). Uses the exact same digest
    # scheme as GroupSync.deterministic_name, but computed directly from the
    # cohort key rather than depending on a Group existing -- deliberately
    # independent of SiteSetting.enable_batch_moderation, which only gates
    # Group auto-provisioning, not cohort-key computation itself.
    def self.cohort_digest_for(user)
      return nil if user.nil?
      key = BatchModeration::GroupSync.cohort_key_for(user)
      return nil if key.blank? || key.length < 2
      BatchModeration::GroupSync.digest_for_key(key)
    end

    # The pre-fix digest formula (plain space-joined values), kept only so
    # Events::Finder#filter_by_calendar_event_scope can still match events
    # that were synced before GroupSync.digest_for_key's collision-safe
    # encoding existed -- those events' stored digest was computed this way
    # and won't match cohort_digest_for's output for the same user anymore.
    # New/re-synced events always get the safe digest via cohort_digest_for.
    def self.legacy_cohort_digest_for(user)
      return nil if user.nil?
      key = BatchModeration::GroupSync.cohort_key_for(user)
      return nil if key.blank? || key.length < 2
      Digest::SHA1.hexdigest(key.map { |_field, value| value }.join(" "))[0, 12]
    end

    # Infers the effective scope for an event's custom_fields, including
    # events saved before `_calendar_event_scope` existed: absence of the new
    # key is not ambiguous, it unambiguously means "saved under the old
    # boolean scheme" (no separation value stored => was a forum event; a
    # separation value stored => was a college-scoped event).
    def self.scope_for(custom_fields)
      explicit = custom_fields[SCOPE_CUSTOM_FIELD_KEY]
      return explicit if VALUES.include?(explicit)

      if custom_fields[DiscourseEvents::CalendarSeparation::RESERVED_CUSTOM_FIELD_KEY].present?
        COLLEGE
      else
        FORUM
      end
    end

    def self.visible_to?(event, user)
      custom_fields = event.custom_fields

      case scope_for(custom_fields)
      when FORUM
        true
      when COLLEGE
        value = custom_fields[DiscourseEvents::CalendarSeparation::RESERVED_CUSTOM_FIELD_KEY]
        value.blank? || value == institution_value_for(user)
      when BATCH
        digest = custom_fields[COHORT_DIGEST_CUSTOM_FIELD_KEY]
        digest.blank? || digest == cohort_digest_for(user)
      end
    end
  end
end
