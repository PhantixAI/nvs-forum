# frozen_string_literal: true

module Jobs
  # Asynchronously send one staff member's batch moderation action-taken email.
  class BatchModerationNotifyStaffEmail < ::Jobs::Base
    def execute(args)
      staff_member = User.find_by(id: args[:staff_member_id])
      return if staff_member.blank?
      return if staff_member.user_option&.email_level == UserOption.email_level_types[:never]

      actor = User.find_by(id: args[:actor_id])
      target = User.find_by(id: args[:target_id])
      return if actor.blank? || target.blank?

      message =
        BatchModerationMailer.action_taken(
          staff_member,
          actor: actor,
          target: target,
          action: args[:action].to_sym,
          reason: args[:reason],
        )
      Email::Sender.new(message, :batch_moderation_action).send
    end
  end
end
