# frozen_string_literal: true

module Jobs
  # Resends one invite with no personalization call at all -- the
  # "ai_personalization: false, schedule_send: true" cell of
  # InvitesController#resend_all_invites's resend matrix. Enqueued once per
  # invite with a staggered delay computed up front by the controller,
  # rather than draining a shared queue like Jobs::ProcessBulkInviteEmails
  # does: that job's claim-lock/chain machinery exists to coordinate
  # multiple concurrent sources feeding one open-ended queue, which doesn't
  # apply here -- this job's whole batch is a closed, already-known list
  # handed to it at enqueue time.
  class ResendInvitesPaced < ::Jobs::Base
    def execute(args)
      invite = Invite.find_by(id: args[:invite_id])
      return if invite.blank?

      invite.resend_invite
    end
  end
end
