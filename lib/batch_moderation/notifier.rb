# frozen_string_literal: true

module BatchModeration
  module Notifier
    def self.notify_staff!(actor:, target:, action:, reason:)
      staff_ids = Group.find(Group::AUTO_GROUPS[:staff]).users.where.not(id: actor.id).pluck(:id)
      return if staff_ids.empty?

      records =
        staff_ids.map do |staff_member_id|
          {
            user_id: staff_member_id,
            notification_type: Notification.types[:batch_moderation_action],
            data: {
              action: action.to_s,
              actor_username: actor.username,
              target_username: target.username,
              target_user_id: target.id,
            }.to_json,
          }
        end

      Notification::Action::BulkCreate.call(records: records, skip_send_email: true)

      # Emails are sent from a background job (retried by Sidekiq on failure)
      # rather than inline, so a slow/failing SMTP send doesn't block the
      # suspend/silence/report request for however many staff members exist.
      staff_ids.each do |staff_member_id|
        Jobs.enqueue(
          :batch_moderation_notify_staff_email,
          staff_member_id: staff_member_id,
          actor_id: actor.id,
          target_id: target.id,
          action: action.to_s,
          reason: reason,
        )
      end
    end

    # A user joined or left a cohort group (via GroupSync.sync, on signup or
    # a profile update that changes their cohort fields). Notifies admins,
    # site moderators, and that cohort's current Batch Moderators -- every
    # time, not just for the affected user's own cohort peers.
    def self.notify_cohort_change(user:, group:, joined:)
      recipient_ids = broad_recipients_for(group, exclude_user_ids: [user.id])
      return if recipient_ids.empty?

      records =
        recipient_ids.map do |recipient_id|
          {
            user_id: recipient_id,
            notification_type: Notification.types[:batch_moderation_cohort_change],
            data: {
              joined: joined,
              user_username: user.username,
              user_id: user.id,
              group_id: group.id,
              group_name: group.full_name,
            }.to_json,
          }
        end

      Notification::Action::BulkCreate.call(records: records, skip_send_email: true)

      recipient_ids.each do |recipient_id|
        Jobs.enqueue(
          :batch_moderation_notify_cohort_change_email,
          recipient_id: recipient_id,
          user_id: user.id,
          group_id: group.id,
          joined: joined,
        )
      end
    end

    # A user's Batch Moderator status was granted or revoked (via
    # Admin::UsersController#grant_batch_moderator/#revoke_batch_moderator,
    # or auto-promotion on an understaffed cohort, where `actor` is nil).
    # Same recipient set as `notify_cohort_change`.
    def self.notify_moderator_status_change(actor:, user:, group:, granted:)
      recipient_ids = broad_recipients_for(group, exclude_user_ids: [user.id, actor&.id].compact)
      return if recipient_ids.empty?

      records =
        recipient_ids.map do |recipient_id|
          {
            user_id: recipient_id,
            notification_type: Notification.types[:batch_moderation_status_change],
            data: {
              granted: granted,
              actor_username: actor&.username,
              user_username: user.username,
              user_id: user.id,
              group_id: group.id,
              group_name: group.full_name,
            }.to_json,
          }
        end

      Notification::Action::BulkCreate.call(records: records, skip_send_email: true)

      recipient_ids.each do |recipient_id|
        Jobs.enqueue(
          :batch_moderation_notify_status_change_email,
          recipient_id: recipient_id,
          actor_id: actor&.id,
          user_id: user.id,
          group_id: group.id,
          granted: granted,
        )
      end
    end

    def self.broad_recipients_for(group, exclude_user_ids:)
      staff_ids = Group.find(Group::AUTO_GROUPS[:staff]).users.pluck(:id)
      cohort_moderator_ids = group.group_users.where(owner: true).pluck(:user_id)
      (staff_ids + cohort_moderator_ids).uniq - exclude_user_ids
    end
    private_class_method :broad_recipients_for
  end
end
