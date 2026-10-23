# frozen_string_literal: true

class EmailLogDetailsSerializer < ApplicationSerializer
  include MailMessagePreviewMixin

  def initialize(email_log, opts)
    super
    @mail = email_log.as_mail_message
  end
end
