# frozen_string_literal: true

class EmailLogDetailsSerializer < ApplicationSerializer
  attributes :headers, :subject, :body

  def initialize(email_log, opts)
    super
    @mail = email_log.as_mail_message
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
