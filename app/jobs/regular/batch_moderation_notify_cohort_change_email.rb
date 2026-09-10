# frozen_string_literal: true

module Jobs
  # Asynchronously send one recipient's cohort-join/leave email.
  class BatchModerationNotifyCohortChangeEmail < ::Jobs::Base
    def execute(args)
      recipient = User.find_by(id: args[:recipient_id])
      return if recipient.blank?
      return if recipient.user_option&.email_level == UserOption.email_level_types[:never]

      user = User.find_by(id: args[:user_id])
      group = Group.find_by(id: args[:group_id])
      return if user.blank? || group.blank?

      message =
        BatchModerationMailer.cohort_change(
          recipient,
          user: user,
          group: group,
          joined: args[:joined],
        )
      Email::Sender.new(message, :batch_moderation_cohort_change).send
    end
  end
end
