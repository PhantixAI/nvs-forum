# frozen_string_literal: true

module Jobs
  class ProcessBulkInviteEmails < ::Jobs::Base
    def execute(args)
      invite_id = pick_next_pending_invite_id
      return if invite_id.nil?

      invite = Invite.find(invite_id)

      personalized_text = BulkInvitePersonalization::Generator.personalize(invite)
      invite.update_columns(
        custom_message: personalized_text,
        emailed_status: Invite.emailed_status_types[:sending],
      )

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
    def pick_next_pending_invite_id
      Invite.transaction do
        Invite
          .where(emailed_status: Invite.emailed_status_types[:bulk_pending])
          .order(:id)
          .lock("FOR UPDATE SKIP LOCKED")
          .limit(1)
          .pick(:id)
      end
    end
  end
end
