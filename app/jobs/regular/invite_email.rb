# frozen_string_literal: true

module Jobs
  # Asynchronously send an email
  class InviteEmail < ::Jobs::Base
    def execute(args)
      raise Discourse::InvalidParameters.new(:invite_id) if args[:invite_id].blank?

      invite = Invite.find_by(id: args[:invite_id])
      return if invite.blank?
      return if !SiteSetting.allow_email_invites

      # to_override lets a caller deliver an unbound (email: nil) invite to a specific
      # address without binding the invite to it -- see Jobs::BulkInvite#send_invite.
      # When it's absent and the invite itself has no bound email (e.g. a bulk_pending
      # invite re-enqueued later by Jobs::ProcessBulkInviteEmails, or a plain resend),
      # fall back to description, where Jobs::BulkInvite stashes the intended recipient.
      # description is also an ordinary, admin-editable note field on every invite
      # (InvitesController#update permits it with no special-casing), so it can end up
      # blank or containing non-email text by the time a resend happens -- validate
      # before sending rather than mailing garbage or crashing on a nil recipient.
      to = args[:to_override] || (invite.email.blank? ? invite.description.presence : nil)
      if invite.email.blank? && (to.blank? || !EmailAddressValidator.valid_value?(to))
        Rails.logger.error(
          "Jobs::InviteEmail: invite #{invite.id} has no valid recipient (description: #{to.inspect}), skipping send",
        )
        return
      end

      message = InviteMailer.send_invite(invite, invite_to_topic: args[:invite_to_topic], to: to)
      Email::Sender.new(message, :invite).send

      if invite.emailed_status != Invite.emailed_status_types[:not_required]
        invite.update_column(:emailed_status, Invite.emailed_status_types[:sent])
      end
    end
  end
end
