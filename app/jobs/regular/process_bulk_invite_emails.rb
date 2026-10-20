# frozen_string_literal: true

module Jobs
  class ProcessBulkInviteEmails < ::Jobs::Base
    CHAIN_KEY = "process_bulk_invite_emails_chain"

    # An invite normally leaves :sending within seconds (Jobs::InviteEmail
    # marks it :sent), so one that has sat there this long belongs to a worker
    # that died mid-job.
    STALE_SENDING_AFTER = 1.hour

    # A chain that dies without clearing its key is replaced once this expires.
    def self.chain_ttl
      (SiteSetting.bulk_invite_email_delay_max_seconds * 3) + 60
    end

    # Every starter (a CSV upload, a resend-all) goes through here rather than
    # enqueueing the job itself: the job re-schedules itself, so each extra
    # chain would send another invite per delay and defeat the pacing.
    def self.ensure_chain!
      return false if !Discourse.redis.set(CHAIN_KEY, 1, ex: chain_ttl, nx: true)

      ::Jobs.enqueue(:process_bulk_invite_emails)
      true
    end

    def execute(args)
      recover_stale_sending_invites

      invite = claim_next_pending_invite
      return end_chain if invite.nil?

      begin
        deliver(invite)
      rescue StandardError => e
        # Not back to :bulk_pending: claiming is in id order, so an invite
        # that always fails would be picked first forever and block the rest.
        Rails.logger.error(
          "[ProcessBulkInviteEmails] invite #{invite.id} could not be sent: #{e.class}: #{e.message}",
        )
        invite.update_columns(emailed_status: Invite.emailed_status_types[:pending])
      end

      reschedule
    end

    private

    # No longer personalizes here -- every invite reaching :bulk_pending has
    # already had its content generated (or confirmed not applicable) by
    # Jobs::GenerateInvitePersonalization, or (for a single-invite resend)
    # synchronously by InvitesController#perform_resend before calling
    # Invite#requeue_for_paced_resend. Personalizing inline here used to mean
    # a slow/variable LLM call (confirmed in production: up to 367s) blocked
    # this method's own send pacing for every other queued invite.
    def deliver(invite)
      ::Jobs.enqueue(:invite_email, invite_id: invite.id)
    end

    def reschedule
      # Overwrite rather than expire, so the key exists again even if it
      # lapsed while this tick was running.
      Discourse.redis.set(CHAIN_KEY, 1, ex: self.class.chain_ttl)

      delay =
        rand(
          SiteSetting.bulk_invite_email_delay_min_seconds..SiteSetting.bulk_invite_email_delay_max_seconds,
        )
      ::Jobs.enqueue_in(delay.seconds, :process_bulk_invite_emails)
    end

    def end_chain
      Discourse.redis.del(CHAIN_KEY)

      # An upload can land between the empty check and the delete above. It
      # saw the key still set and started no chain, so look again.
      self.class.ensure_chain! if pending_invites.exists?
    end

    def pending_invites
      Invite.where(emailed_status: Invite.emailed_status_types[:bulk_pending])
    end

    # Jobs::InviteEmail sends the actual email (Email::Sender#send, which
    # creates the EmailLog row) *before* it records emailed_status: :sent --
    # a worker killed in that narrow window (confirmed in production: the
    # same Redis/Sidekiq disruption that stalled this whole chain also did
    # this to at least one invite) leaves a genuinely-delivered invite stuck
    # in :sending. Blindly resetting every stale :sending invite back to
    # :bulk_pending, as this used to do, would silently re-claim and
    # re-send (double-delivering) exactly those -- so only requeue ones
    # with no delivery record since they entered :sending; one that does
    # have one just needs its bookkeeping reconciled to :sent instead.
    def recover_stale_sending_invites
      Invite
        .where(emailed_status: Invite.emailed_status_types[:sending])
        .where("updated_at < ?", STALE_SENDING_AFTER.ago)
        .find_each do |invite|
          delivered =
            EmailLog
              .where(invite_id: invite.id, email_type: "invite")
              .where("created_at >= ?", invite.updated_at)
              .exists?

          invite.update_column(
            :emailed_status,
            (
              if delivered
                Invite.emailed_status_types[:sent]
              else
                Invite.emailed_status_types[:bulk_pending]
              end
            ),
          )
        end
    end

    # FOR UPDATE SKIP LOCKED makes "pick and claim one row" atomic across
    # concurrent executions of this job (a Sidekiq retry, or an overlapping
    # run) without needing a separate distributed lock -- two concurrent
    # invocations simply grab two different rows instead of racing on one.
    # The status flip to :sending must happen inside the same transaction
    # that holds the row lock -- otherwise the lock releases at commit while
    # the row is still :bulk_pending, leaving a window where a second
    # invocation's own SKIP LOCKED select can claim and double-send it.
    # updated_at is bumped so recover_stale_sending_invites measures time
    # spent in :sending, not the invite's age.
    def claim_next_pending_invite
      Invite.transaction do
        invite = pending_invites.order(:id).lock("FOR UPDATE SKIP LOCKED").limit(1).first
        invite&.update_columns(
          emailed_status: Invite.emailed_status_types[:sending],
          updated_at: Time.zone.now,
        )
        invite
      end
    end
  end
end
