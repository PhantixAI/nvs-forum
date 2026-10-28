# frozen_string_literal: true

RSpec.describe Jobs::ProcessSnsNotification do
  let(:ses_message_id) { "010901a075d1bd53-2bdf9bfa-57d6-41e7-a08f-e1884959e9a6-000000" }
  let(:message_id) { "abc123@mail.example.com" }
  let(:topic_arn) { "arn:aws:sns:us-east-1:123456789012:discourse-ses-events" }

  let!(:email_log) { Fabricate(:email_log, message_id: message_id) }

  # The original Message-ID header, not the SES-assigned id, is what
  # EmailLog#message_id is matched against (see WebhooksController#aws specs).
  let(:mail) do
    {
      "messageId" => ses_message_id,
      "headers" => [{ "name" => "Message-ID", "value" => "<#{message_id}>" }],
    }
  end

  def notification_args(message)
    json = { "TopicArn" => topic_arn, "Message" => message.to_json }
    { raw: json.to_json, json: json }
  end

  before do
    Email::Sns.stubs(:allowed_topic_arn?).returns(true)
    Email::Sns.stubs(:authentic?).returns(true)
  end

  it "does nothing when the topic arn is not allowlisted" do
    Email::Sns.stubs(:allowed_topic_arn?).returns(false)
    message = {
      "notificationType" => "Bounce",
      "mail" => mail,
      "bounce" => {
        "bounceType" => "Permanent",
        "bouncedRecipients" => [{ "emailAddress" => email_log.to_address, "status" => "5.1.1" }],
      },
    }

    described_class.new.execute(notification_args(message))

    expect(email_log.reload.bounced).to eq(false)
  end

  it "does nothing when the SNS signature is not authentic" do
    Email::Sns.stubs(:authentic?).returns(false)
    message = {
      "notificationType" => "Bounce",
      "mail" => mail,
      "bounce" => {
        "bounceType" => "Permanent",
        "bouncedRecipients" => [{ "emailAddress" => email_log.to_address, "status" => "5.1.1" }],
      },
    }

    described_class.new.execute(notification_args(message))

    expect(email_log.reload.bounced).to eq(false)
  end

  it "does nothing for an unrecognized notification type" do
    message = { "notificationType" => "SomeFutureType", "mail" => mail }

    expect { described_class.new.execute(notification_args(message)) }.not_to raise_error
  end

  it "does nothing for a malformed message body" do
    json = { "TopicArn" => topic_arn, "Message" => "not json" }

    expect { described_class.new.execute(raw: json.to_json, json: json) }.not_to raise_error
  end

  describe "Bounce notifications" do
    it "marks the matching EmailLog as bounced by the original message ID" do
      message = {
        "notificationType" => "Bounce",
        "mail" => mail,
        "bounce" => {
          "bounceType" => "Permanent",
          "bouncedRecipients" => [{ "emailAddress" => email_log.to_address, "status" => "5.1.1" }],
        },
      }

      described_class.new.execute(notification_args(message))

      email_log.reload
      expect(email_log.bounced).to eq(true)
      expect(email_log.bounce_error_code).to eq("5.1.1")
    end

    # The SES-assigned id (mail.messageId) is never used for matching, even
    # when it happens to equal a stored EmailLog#ses_message_id -- only the
    # original Message-ID header, matched against EmailLog#message_id, counts.
    it "does not match on the SES-assigned id alone, without an original message ID header" do
      email_log.update!(message_id: nil, ses_message_id: ses_message_id)
      message = {
        "notificationType" => "Bounce",
        "mail" => {
          "messageId" => ses_message_id,
        },
        "bounce" => {
          "bounceType" => "Permanent",
          "bouncedRecipients" => [{ "emailAddress" => email_log.to_address, "status" => "5.1.1" }],
        },
      }

      described_class.new.execute(notification_args(message))

      expect(email_log.reload.bounced).to eq(false)
    end

    it "does nothing when no EmailLog matches" do
      message = {
        "notificationType" => "Bounce",
        "mail" => {
          "messageId" => ses_message_id,
          "headers" => [{ "name" => "Message-ID", "value" => "<unmatched-id@example.com>" }],
        },
        "bounce" => {
          "bounceType" => "Permanent",
          "bouncedRecipients" => [{ "emailAddress" => "nobody@example.com", "status" => "5.1.1" }],
        },
      }

      expect { described_class.new.execute(notification_args(message)) }.not_to raise_error
    end

    it "does not overwrite an existing delivery or complaint" do
      message = {
        "notificationType" => "Bounce",
        "mail" => mail,
        "bounce" => {
          "bounceType" => "Permanent",
          "bouncedRecipients" => [{ "emailAddress" => email_log.to_address, "status" => "5.1.1" }],
        },
      }

      email_log.update!(delivered_at: Time.current)
      described_class.new.execute(notification_args(message))
      expect(email_log.reload.bounced).to eq(false)

      email_log.update!(delivered_at: nil, complained_at: Time.current)
      described_class.new.execute(notification_args(message))
      expect(email_log.reload.bounced).to eq(false)
    end
  end

  describe "Delivery notifications" do
    it "sets delivered_at on the matching EmailLog" do
      message = {
        "notificationType" => "Delivery",
        "mail" => mail,
        "delivery" => {
          "recipients" => [email_log.to_address],
        },
      }

      described_class.new.execute(notification_args(message))

      expect(email_log.reload.delivered_at).to be_present
    end

    it "does not overwrite an existing bounce" do
      email_log.update!(bounced: true)
      message = {
        "notificationType" => "Delivery",
        "mail" => mail,
        "delivery" => {
          "recipients" => [email_log.to_address],
        },
      }

      described_class.new.execute(notification_args(message))

      expect(email_log.reload.delivered_at).to eq(nil)
    end
  end

  describe "Complaint notifications" do
    it "sets complained_at on the matching EmailLog" do
      message = {
        "notificationType" => "Complaint",
        "mail" => mail,
        "complaint" => {
          "complainedRecipients" => [{ "emailAddress" => email_log.to_address }],
        },
      }

      described_class.new.execute(notification_args(message))

      expect(email_log.reload.complained_at).to be_present
    end

    it "does not overwrite an existing bounce" do
      email_log.update!(bounced: true)
      message = {
        "notificationType" => "Complaint",
        "mail" => mail,
        "complaint" => {
          "complainedRecipients" => [{ "emailAddress" => email_log.to_address }],
        },
      }

      described_class.new.execute(notification_args(message))

      expect(email_log.reload.complained_at).to eq(nil)
    end
  end
end
