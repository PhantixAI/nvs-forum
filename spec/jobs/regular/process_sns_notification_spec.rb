# frozen_string_literal: true

RSpec.describe Jobs::ProcessSnsNotification do
  let(:ses_message_id) { "010901a075d1bd53-2bdf9bfa-57d6-41e7-a08f-e1884959e9a6-000000" }
  let(:topic_arn) { "arn:aws:sns:us-east-1:123456789012:discourse-ses-events" }

  let!(:email_log) { Fabricate(:email_log, ses_message_id: ses_message_id) }

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

  it "does nothing when the SNS signature is not authentic" do
    Email::Sns.stubs(:authentic?).returns(false)
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

  it "does nothing for an unrecognized notification type" do
    message = {
      "notificationType" => "SomeFutureType",
      "mail" => {
        "messageId" => ses_message_id,
      },
    }

    expect { described_class.new.execute(notification_args(message)) }.not_to raise_error
  end

  it "does nothing for a malformed message body" do
    json = { "TopicArn" => topic_arn, "Message" => "not json" }

    expect { described_class.new.execute(raw: json.to_json, json: json) }.not_to raise_error
  end

  describe "Bounce notifications" do
    it "marks the matching EmailLog as bounced by ses_message_id" do
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

      email_log.reload
      expect(email_log.bounced).to eq(true)
      expect(email_log.bounce_error_code).to eq("5.1.1")
    end

    it "does not match on the old locally-generated message_id" do
      email_log.update!(message_id: "some-local-id@example.com", ses_message_id: nil)
      message = {
        "notificationType" => "Bounce",
        "mail" => {
          "messageId" => "some-local-id@example.com",
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
          "messageId" => "unmatched-id",
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
        "mail" => {
          "messageId" => ses_message_id,
        },
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
        "mail" => {
          "messageId" => ses_message_id,
        },
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
        "mail" => {
          "messageId" => ses_message_id,
        },
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
        "mail" => {
          "messageId" => ses_message_id,
        },
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
        "mail" => {
          "messageId" => ses_message_id,
        },
        "complaint" => {
          "complainedRecipients" => [{ "emailAddress" => email_log.to_address }],
        },
      }

      described_class.new.execute(notification_args(message))

      expect(email_log.reload.complained_at).to eq(nil)
    end
  end
end
