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
        reserved_key = DiscourseEvents::CalendarSeparation::RESERVED_CUSTOM_FIELD_KEY
        existing_separation_value = event.custom_fields[reserved_key]

        attributes = Event::Action::AttributesFromRaw.call(raw_event:, current_status: event.status)
        attributes[:image_upload_id] = Event::Action::ResolveImageUpload.call(
          image: raw_event[:image],
          post:,
        )&.id

        is_forum_event = raw_event[:"forum-event"]&.downcase == "true"
        custom_fields = attributes[:custom_fields].dup
        if is_forum_event
          custom_fields.delete(reserved_key)
        else
          # `last_editor` falls back to `post.user` when the post has never been edited, so
          # this is correct for a brand-new event (creator) and for the rare edit of a legacy
          # event with no separation value yet (the person actually setting it, not the OP).
          separation_value =
            existing_separation_value.presence ||
              DiscourseEvents::CalendarSeparation.value_for_user(post.last_editor)
          custom_fields[reserved_key] = separation_value if separation_value.present?
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
