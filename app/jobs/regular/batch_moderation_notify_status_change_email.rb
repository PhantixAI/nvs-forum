# frozen_string_literal: true

module Jobs
  # Asynchronously send one recipient's Batch Moderator grant/revoke email.
  class BatchModerationNotifyStatusChangeEmail < ::Jobs::Base
    def execute(args)
      recipient = User.find_by(id: args[:recipient_id])
      return if recipient.blank?
      return if recipient.user_option&.email_level == UserOption.email_level_types[:never]

      user = User.find_by(id: args[:user_id])
      group = Group.find_by(id: args[:group_id])
      return if user.blank? || group.blank?

      actor = args[:actor_id] ? User.find_by(id: args[:actor_id]) : nil

      message =
        BatchModerationMailer.status_change(
          recipient,
          actor: actor,
          user: user,
          group: group,
          granted: args[:granted],
        )
      Email::Sender.new(message, :batch_moderation_status_change).send
    end
  end
end
