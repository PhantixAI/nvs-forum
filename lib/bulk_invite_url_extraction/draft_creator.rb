# frozen_string_literal: true

require "csv"

module BulkInviteUrlExtraction
  # Turns the admin-reviewed CSV textarea from the "Extract from URL" bulk
  # invite tab into draft Invite rows (emailed_status: :draft), held for
  # review until an explicit send (see InvitesController#send_drafts).
  #
  # Deliberately not routed through Jobs::BulkInvite: that job's
  # orchestration (notifications, Jobs::ProcessBulkInviteEmails chaining) is
  # specifically about *sending*, which a draft must never trigger, and its
  # CSV schema (arbitrary User Field columns, allow_any_email-based volume
  # routing) doesn't match this flow's fixed, smaller column set
  # (email,name,groups,topic_id,locale,keywords). The "locale" column is
  # read but intentionally not persisted -- Invite has no locale column
  # (locale is only ever set on the redeeming User at send time, which a
  # draft has none of yet); sent drafts use the site's default locale.
  module DraftCreator
    Result = Struct.new(:created_count, :errors, keyword_init: true)

    def self.create_drafts(
      current_user:,
      csv_text:,
      allow_any_email:,
      schedule_send:,
      skip_personalization:
    )
      guardian = Guardian.new(current_user)
      errors = []
      created = 0

      CSV
        .parse(csv_text.to_s, headers: true, skip_blanks: true)
        .each do |row|
          email = row["email"].to_s.strip
          next if email.blank?

          if !EmailAddressValidator.valid_value?(email)
            errors << "Invalid email '#{email}'"
            next
          end

          groups = resolve_groups(row["groups"], guardian, errors, email)
          topic = resolve_topic(row["topic_id"], guardian, errors, email)

          begin
            Invite.generate(
              current_user,
              email: allow_any_email ? nil : email,
              description: allow_any_email ? email : nil,
              topic: topic,
              group_ids: groups.map(&:id),
              recipient_name: row["name"].presence,
              recipient_keywords: row["keywords"].presence,
              allow_any_email: allow_any_email,
              schedule_send: schedule_send,
              skip_personalization: skip_personalization,
              emailed_status: Invite.emailed_status_types[:draft],
            )
            created += 1
          rescue Invite::UserExists, ActiveRecord::RecordInvalid, RateLimiter::LimitExceeded => e
            errors << "#{email}: #{e.message}"
          end
        end

      Result.new(created_count: created, errors: errors)
    end

    def self.resolve_groups(group_names, guardian, errors, email)
      return [] if group_names.blank?

      group_names
        .split(";")
        .filter_map do |group_name|
          group = Group.find_by("lower(name) = ?", group_name.strip.downcase)
          if group && guardian.can_edit_group?(group)
            group
          else
            errors << "Invalid group '#{group_name}' for '#{email}'"
            nil
          end
        end
    end
    private_class_method :resolve_groups

    def self.resolve_topic(topic_id, guardian, errors, email)
      return nil if topic_id.blank?

      topic = Topic.find_by_id(topic_id)
      if topic.nil? || !guardian.can_invite_to?(topic)
        errors << "Invalid topic ID '#{topic_id}' for '#{email}'"
        return nil
      end

      topic
    end
    private_class_method :resolve_topic
  end
end
