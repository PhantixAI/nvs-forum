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
      return unless message_id = message.dig("mail", "messageId").presence
      return unless bounce_type = message.dig("bounce", "bounceType").presence

      Array(message.dig("bounce", "bouncedRecipients")).each do |r|
        email_log = find_email_log(message_id, r["emailAddress"])
        next if email_log.nil? || email_log.bounced?
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

    def process_delivery(message)
      return unless message_id = message.dig("mail", "messageId").presence

      Array(message.dig("delivery", "recipients")).each do |email_address|
        email_log = find_email_log(message_id, email_address)
        next if email_log.nil? || email_log.bounced? || email_log.complained_at
        next if email_log.delivered_at

        email_log.update!(delivered_at: Time.current)
      end
    end

    def process_complaint(message)
      return unless message_id = message.dig("mail", "messageId").presence

      Array(message.dig("complaint", "complainedRecipients")).each do |r|
        email_log = find_email_log(message_id, r["emailAddress"])
        next if email_log.nil? || email_log.bounced? || email_log.complained_at

        email_log.update!(complained_at: Time.current)
      end
    end

    def find_email_log(message_id, email_address)
      return if email_address.blank?
      EmailLog.find_by(ses_message_id: message_id, to_address: email_address)
    end
  end
end
