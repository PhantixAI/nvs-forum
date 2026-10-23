# frozen_string_literal: true

# Previews an invite's currently staged (not yet delivered) content --
# InviteMailer.send_invite builds the same Mail::Message a real send would
# (template selection, AI-personalized vs custom vs default), just never
# handed to Email::Sender. See Admin::EmailLogsController#invite_draft.
class InviteDraftPreviewSerializer < ApplicationSerializer
  include MailMessagePreviewMixin

  def initialize(message, opts)
    super
    @mail = message
  end
end
