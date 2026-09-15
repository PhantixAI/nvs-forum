# frozen_string_literal: true

module Jobs
  class ProcessBulkInviteEmails < ::Jobs::Base
    def execute(args)
      invite = claim_next_pending_invite
      return if invite.nil?

      personalized_text = BulkInvitePersonalization::Generator.personalize(invite)
      invite.update_columns(custom_message: personalized_text)

      ::Jobs.enqueue(:invite_email, invite_id: invite.id)

      delay =
        rand(
          SiteSetting.bulk_invite_email_delay_min_seconds..SiteSetting.bulk_invite_email_delay_max_seconds,
        )
      ::Jobs.enqueue_in(delay.seconds, :process_bulk_invite_emails)
    end

    private

    # FOR UPDATE SKIP LOCKED makes "pick and claim one row" atomic across
    # concurrent executions of this job (a Sidekiq retry, or two overlapping
    # Jobs::BulkInvite runs each spawning their own self-rescheduling chain)
    # without needing a separate distributed lock -- two concurrent
    # invocations simply grab two different rows instead of racing on one.
    # The status flip to :sending must happen inside the same transaction
    # that holds the row lock -- otherwise the lock releases at commit while
    # the row is still :bulk_pending, leaving a window where a second
    # invocation's own SKIP LOCKED select can claim and double-send it.
    def claim_next_pending_invite
      Invite.transaction do
        invite =
          Invite
            .where(emailed_status: Invite.emailed_status_types[:bulk_pending])
            .order(:id)
            .lock("FOR UPDATE SKIP LOCKED")
            .limit(1)
            .first
        invite&.update_columns(emailed_status: Invite.emailed_status_types[:sending])
        invite
      end
    end
  end
end
