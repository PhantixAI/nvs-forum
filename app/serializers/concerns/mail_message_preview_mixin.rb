# frozen_string_literal: true

# Shared subject/body/header extraction from a Mail::Message -- used by both
# EmailLogDetailsSerializer (a message reconstructed from an already-sent
# EmailLog) and InviteDraftPreviewSerializer (a message built fresh, without
# delivering, as a preview of staged-but-unsent content). Both set @mail in
# #initialize before relying on these.
module MailMessagePreviewMixin
  def self.included(klass)
    klass.attributes :headers, :subject, :body
  end

  def headers
    @mail&.header.to_s
  end

  def subject
    @mail&.subject.presence || I18n.t("emails.incoming.no_subject")
  end

  def body
    body =
      begin
        @mail&.text_part&.decoded
      rescue StandardError
        nil
      end
    body ||=
      begin
        @mail&.html_part&.decoded
      rescue StandardError
        nil
      end
    body ||=
      begin
        @mail&.body&.decoded
      rescue StandardError
        nil
      end

    return I18n.t("emails.incoming.no_body") if body.blank?

    body.encode("utf-8", invalid: :replace, undef: :replace, replace: "").strip
  end
end
