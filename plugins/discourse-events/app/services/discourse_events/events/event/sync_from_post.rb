# frozen_string_literal: true

module DiscourseEvents
  module Events
    # Creates, updates or removes a post's event to match the `[event]` block in its raw.
    class Event::SyncFromPost
      include Service::Base

      params do
        attribute :post_id, :integer

        validates :post_id, presence: true
      end

      model :post
      model :raw_event, :parse_event, optional: true

      only_if :event_removed do
        step :remove_event
      end

      only_if :event_present do
        model :event, :upsert_event
        step :schedule_topic_bump
      end

      private

      def fetch_post(params:)
        Post.find_by(id: params.post_id)
      end

      def parse_event(post:)
        Parser.extract_events(post).first
      end

      def event_removed(raw_event:, post:)
        return if raw_event.present?
        post.event.present?
      end

      def event_present(raw_event:)
        raw_event.present?
      end

      def remove_event(post:)
        post.event.destroy!
      end

      def upsert_event(post:, raw_event:)
        event = post.event || Event.new(id: post.id)
        separation_key = DiscourseEvents::CalendarSeparation::RESERVED_CUSTOM_FIELD_KEY
        scope_key = DiscourseEvents::CalendarEventScope::SCOPE_CUSTOM_FIELD_KEY
        digest_key = DiscourseEvents::CalendarEventScope::COHORT_DIGEST_CUSTOM_FIELD_KEY
        existing_separation_value = event.custom_fields[separation_key]
        existing_digest = event.custom_fields[digest_key]

        attributes = Event::Action::AttributesFromRaw.call(raw_event:, current_status: event.status)
        attributes[:image_upload_id] = Event::Action::ResolveImageUpload.call(
          image: raw_event[:image],
          post:,
        )&.id

        requested_scope = raw_event[:"event-scope"]
        if DiscourseEvents::CalendarEventScope::VALUES.exclude?(requested_scope)
          # No (or an unrecognized) `event-scope` attribute in the raw markdown. A brand-new
          # event defaults to Batch Event per spec; re-saving an existing event (e.g. a legacy
          # event from before this scope existed, edited via a surface that doesn't thread the
          # attribute through, like the rich editor or raw-source composer) must NOT silently
          # narrow it -- fall back to its own currently-persisted (or legacy-inferred) scope
          # instead of defaulting to "batch".
          requested_scope =
            if event.new_record?
              DiscourseEvents::CalendarEventScope::BATCH
            else
              DiscourseEvents::CalendarEventScope.scope_for(event.custom_fields)
            end
        end

        custom_fields = attributes[:custom_fields].dup
        # `last_editor` falls back to `post.user` when the post has never been edited, so
        # this is correct for a brand-new event (creator) and for the rare edit of a legacy
        # event with no separation value/digest yet (the person actually setting it, not the OP).
        creator = post.last_editor

        case requested_scope
        when DiscourseEvents::CalendarEventScope::FORUM
          custom_fields.delete(separation_key)
          custom_fields.delete(digest_key)
          custom_fields[scope_key] = DiscourseEvents::CalendarEventScope::FORUM
        when DiscourseEvents::CalendarEventScope::BATCH
          separation_value =
            existing_separation_value.presence ||
              DiscourseEvents::CalendarSeparation.value_for_user(creator)
          digest =
            existing_digest.presence ||
              DiscourseEvents::CalendarEventScope.cohort_digest_for(creator)

          custom_fields[separation_key] = separation_value if separation_value.present?
          if digest.present?
            custom_fields[digest_key] = digest
            custom_fields[scope_key] = DiscourseEvents::CalendarEventScope::BATCH
          else
            # Cohort isn't fully resolvable (missing batch value, or a staff-type
            # creator whose cohort key is institution-only) -- collapse to the next
            # broadest scope the creator's data actually supports, rather than an
            # event nobody but its author could ever find.
            custom_fields.delete(digest_key)
            custom_fields[scope_key] = DiscourseEvents::CalendarEventScope::COLLEGE
          end
        else # college
          separation_value =
            existing_separation_value.presence ||
              DiscourseEvents::CalendarSeparation.value_for_user(creator)
          custom_fields.delete(digest_key)
          custom_fields[separation_key] = separation_value if separation_value.present?
          custom_fields[scope_key] = DiscourseEvents::CalendarEventScope::COLLEGE
        end
        attributes[:custom_fields] = custom_fields

        # Event#apply_params_for_status's non-raising branch (`update`) returns
        # `self` on a rejected save exactly like it does on success, relying on
        # `update` having populated `errors` for callers to notice. A save
        # rejected by something that *doesn't* add to `errors` (e.g. a halted
        # callback) would then come back looking like a valid, saved model. Use
        # the raising form instead so any rejected save surfaces loudly -- as an
        # invalid-model result when validations populated errors (rescued below,
        # same outcome as before), or as an uncaught exception otherwise, rather
        # than a silent no-op.
        event.update_with_params!(attributes)
      rescue ActiveRecord::RecordInvalid => e
        e.record
      end

      def schedule_topic_bump(event:)
        event.set_topic_bump
      end
    end
  end
end
