# frozen_string_literal: true

module Jobs
  # Recovers invites orphaned by Invite.claim_for_drafting -- see that
  # method's own comment for why a claimed invite can otherwise be stuck
  # forever once the job that claimed it dies mid-batch.
  class RequeueStaleDraftingInvites < ::Jobs::Scheduled
    every 15.minutes

    def execute(_args)
      Invite.requeue_stale_drafting
    end
  end
end
