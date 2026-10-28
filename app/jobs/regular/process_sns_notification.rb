# frozen_string_literal: true

module Jobs
  class ProcessSnsNotification < ::Jobs::Base
    sidekiq_options retry: false

    def execute(args)
      return unless raw = args[:raw].presence
      return unless json = args[:json].presence
      return unless message = json["Message"].presence

      message =
        begin
          JSON.parse(message)
        rescue JSON::ParserError
          nil
        end
      return unless message

      return if !Email::Sns.allowed_topic_arn?(json["TopicArn"])
      return unless Email::Sns.authentic?(raw)

      case message["notificationType"]
      when "Bounce"
        process_bounce(message)
      when "Delivery"
        process_delivery(message)
      when "Complaint"
        process_complaint(message)
      end
    end

    private

    # None of Bounce/Delivery/Complaint should overwrite a different one of
    # the three that already landed on the same EmailLog -- SES notifications
    # can arrive out of order, and once one of these terminal outcomes is
    # recorded it's the more useful signal than a later, contradictory one.
    def process_bounce(message)
      message_id = original_message_id(message["mail"])
      return log_no_message_id("Bounce", message["mail"]) if message_id.nil?
      return unless bounce_type = message.dig("bounce", "bounceType").presence

      Array(message.dig("bounce", "bouncedRecipients")).each do |r|
        email_log = find_email_log(message_id, r["emailAddress"])
        if email_log.nil?
          log_no_match("Bounce", message_id, r["emailAddress"])
          next
        end
        next if email_log.bounced?
        next if email_log.delivered_at || email_log.complained_at

        email_log.update!(bounced: true, bounce_error_code: r["status"])

        next if email_log.user&.email.blank?

        if email_log.user.user_stat.bounce_score.to_s.start_with?("4.") ||
             bounce_type == "Transient"
          Email::Receiver.update_bounce_score(email_log.user.email, SiteSetting.soft_bounce_score)
        else
          Email::Receiver.update_bounce_score(email_log.user.email, SiteSetting.hard_bounce_score)
        end
      end
    end

    def original_message_id(mail)
      header =
        Array(mail&.dig("headers")).find { |entry| entry["name"].to_s.casecmp?("Message-ID") }
      message_id = header&.dig("value").presence || mail&.dig("commonHeaders", "messageId").presence
      # Provider-assigned IDs do not identify the original message stored in EmailLog.
      Email::MessageIdService.message_id_clean(message_id.strip) if message_id
    end

    def process_delivery(message)
      message_id = original_message_id(message["mail"])
      return log_no_message_id("Delivery", message["mail"]) if message_id.nil?

      Array(message.dig("delivery", "recipients")).each do |email_address|
        email_log = find_email_log(message_id, email_address)
        if email_log.nil?
          log_no_match("Delivery", message_id, email_address)
          next
        end
        next if email_log.bounced? || email_log.complained_at
        next if email_log.delivered_at

        email_log.update!(delivered_at: Time.current)
      end
    end

    def process_complaint(message)
      message_id = original_message_id(message["mail"])
      return log_no_message_id("Complaint", message["mail"]) if message_id.nil?

      Array(message.dig("complaint", "complainedRecipients")).each do |r|
        email_log = find_email_log(message_id, r["emailAddress"])
        if email_log.nil?
          log_no_match("Complaint", message_id, r["emailAddress"])
          next
        end
        next if email_log.bounced? || email_log.complained_at

        email_log.update!(complained_at: Time.current)
      end
    end

    def find_email_log(message_id, email_address)
      return if email_address.blank?
      EmailLog.find_by(message_id: message_id, to_address: email_address)
    end

    # Surfaces in Logster (admin-visible at /logs) exactly why a Bounce/
    # Delivery/Complaint notification silently no-ops, since a mismatch here
    # otherwise looks identical to a notification that was never sent at all.
    def log_no_message_id(type, mail)
      Rails.logger.warn(
        "[ProcessSnsNotification] no original Message-ID found for a #{type} notification " \
          "(headers_present=#{mail&.dig("headers").present?}, " \
          "common_headers_message_id=#{mail&.dig("commonHeaders", "messageId").inspect}, " \
          "ses_message_id=#{mail&.dig("messageId").inspect})",
      )
    end

    def log_no_match(type, message_id, email_address)
      Rails.logger.warn(
        "[ProcessSnsNotification] no EmailLog matched a #{type} notification " \
          "(message_id=#{message_id.inspect}, email_address=#{email_address.inspect})",
      )
    end
  end
end
