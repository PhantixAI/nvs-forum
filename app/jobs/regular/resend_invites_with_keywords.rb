# frozen_string_literal: true

module Jobs
  # Regenerates and resends one request-scoped batch of invites with ad-hoc
  # keywords, enqueued by InvitesController#resend_all_invites. Deliberately
  # separate from Jobs::ProcessBulkInviteEmails, which only ever reads
  # keywords off the persisted invites.recipient_keywords column and scans
  # the whole bulk_pending queue -- it has no way to thread a one-off,
  # per-request keyword string through to the invites this job is scoped to.
  class ResendInvitesWithKeywords < ::Jobs::Base
    def execute(args)
      extra_keywords = args[:extra_keywords]

      Invite.where(id: args[:invite_ids]).find_each { |invite| deliver(invite, extra_keywords) }
    end

    private

    def deliver(invite, extra_keywords)
      result =
        BulkInvitePersonalization::Generator.personalize(invite, extra_keywords: extra_keywords)
      if result.present?
        invite.update_columns(custom_subject: result[:subject], custom_message: result[:body])
      end

      invite.resend_invite
    rescue BulkInvitePersonalization::Generator::GenerationFailed => e
      # Matches ProcessBulkInviteEmails#deliver: skip rather than retry
      # against a provider that is still failing, so one invite can't block
      # the rest of this batch -- an admin resends it again afterwards.
      Rails.logger.error("[ResendInvitesWithKeywords] invite #{invite.id} skipped -- #{e.message}")
      invite.update_columns(emailed_status: Invite.emailed_status_types[:skipped])
    end
  end
end
