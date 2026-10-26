# frozen_string_literal: true

require "csv"

module BulkInviteUrlExtraction
  # Turns the admin-reviewed CSV textarea from the "Extract from URL" bulk
  # invite tab into draft Invite rows (emailed_status: :review), held for
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
      ai_personalization:,
      source_url: nil
    )
      guardian = Guardian.new(current_user)
      errors = []
      created = 0
      # Tracks emails already handled by this same CSV, since a row-level
      # duplicate (the same roster entry appearing twice, e.g. from a
      # re-extraction merged into an already-edited textarea) would
      # otherwise sail past the one-at-a-time existing-invite check below --
      # each iteration only sees what's already in the database, not its own
      # earlier iterations within the same call.
      seen_emails = Set.new

      CSV
        .parse(csv_text.to_s, headers: true, skip_blanks: true)
        .each do |row|
          email = row["email"].to_s.strip
          next if email.blank?

          if !EmailAddressValidator.valid_value?(email)
            errors << "Invalid email '#{email}'"
            next
          end

          normalized_email = Email.downcase(email)
          if !seen_emails.add?(normalized_email)
            errors << "Duplicate row for '#{email}' -- skipped"
            next
          end

          # allow_any_email leaves Invite.generate's own email: opt nil (see
          # below), which also disables its built-in existing-invite lookup
          # (keyed on the email column) -- Jobs::BulkInvite#send_invite has
          # the exact same gap for the same reason. Check both columns
          # ourselves so re-extracting/re-submitting the same roster updates
          # the existing invite instead of creating another one for the same
          # recipient. The default scope already excludes soft-deleted
          # invites (see Trashable); only a still-live one blocks a new row.
          if Invite
               .where(invited_by_id: current_user.id)
               .where("email = :email OR description = :email", email: normalized_email)
               .where("expires_at > ?", Time.zone.now)
               .exists?
            errors << "'#{email}' already has an invite -- skipped"
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
              source_url: source_url,
              ai_personalization: ai_personalization,
              emailed_status: Invite.emailed_status_types[:review],
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
