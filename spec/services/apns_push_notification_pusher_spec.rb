# frozen_string_literal: true

RSpec.describe ApnsPushNotificationPusher do
  fab!(:user)
  fab!(:post)

  let(:payload) do
    {
      notification_type: 1,
      post_url: "/t/#{post.topic_id}/#{post.post_number}",
      excerpt: "Hello you",
    }
  end

  let(:connection) { instance_double(Apnotic::Connection, push: ok_response, close: nil) }
  let(:ok_response) { instance_double(Apnotic::Response, ok?: true, status: "200", body: nil) }

  def setup_ios_client(user, client_id: SecureRandom.hex)
    client = Fabricate(:user_api_key_client, client_id: client_id, application_name: "TestApp")
    Fabricate(
      :user_api_key,
      user: user,
      scopes: ["notifications"].map { |name| UserApiKeyScope.new(name: name) },
      push_url: "ios",
      user_api_key_client_id: client.id,
    )
  end

  before do
    SiteSetting.apple_pem = "test-auth-key"
    SiteSetting.apple_key_id = "test-key-id"
    SiteSetting.apple_team_id = "test-team-id"
    SiteSetting.apns_bundle_id = "com.example.app"

    allow(Apnotic::Connection).to receive(:new).and_return(connection)
  end

  it "does nothing when no ios clients exist" do
    described_class.push(user, payload)
    expect(Apnotic::Connection).not_to have_received(:new)
  end

  it "does nothing when apple_pem is blank" do
    SiteSetting.apple_pem = ""
    setup_ios_client(user)

    described_class.push(user, payload)
    expect(Apnotic::Connection).not_to have_received(:new)
  end

  it "pushes a notification with the title, body, url and apns topic for each ios client" do
    setup_ios_client(user, client_id: "device-token-1")

    described_class.push(user, payload)

    expect(connection).to have_received(:push) do |notification|
      expect(notification.token).to eq("device-token-1")
      expect(notification.alert[:body]).to eq("Hello you")
      expect(notification.custom_payload[:discourse_url]).to include(
        "/t/#{post.topic_id}/#{post.post_number}",
      )
      expect(notification.topic).to eq("com.example.app")
      expect(notification.priority).to eq(10)
      expect(notification.push_type).to eq("alert")
    end
  end

  it "pushes a separate notification per registered ios client" do
    setup_ios_client(user, client_id: "device-token-1")
    setup_ios_client(user, client_id: "device-token-2")

    described_class.push(user, payload)

    expect(connection).to have_received(:push).twice
  end

  it "ignores android clients" do
    client = Fabricate(:user_api_key_client, application_name: "TestApp")
    Fabricate(
      :user_api_key,
      user: user,
      scopes: ["notifications"].map { |name| UserApiKeyScope.new(name: name) },
      push_url: "android",
      user_api_key_client_id: client.id,
    )

    described_class.push(user, payload)
    expect(Apnotic::Connection).not_to have_received(:new)
  end

  it "closes the connection after pushing" do
    setup_ios_client(user)

    described_class.push(user, payload)

    expect(connection).to have_received(:close)
  end

  context "when the production endpoint rejects a sandbox-issued token" do
    let(:bad_token_response) do
      instance_double(
        Apnotic::Response,
        ok?: false,
        status: "400",
        body: {
          "reason" => "BadDeviceToken",
        },
      )
    end
    let(:sandbox_connection) { instance_double(Apnotic::Connection, push: ok_response, close: nil) }

    before do
      allow(connection).to receive(:push).and_return(bad_token_response)
      allow(Apnotic::Connection).to receive(:development).and_return(sandbox_connection)
    end

    it "retries the notification against the sandbox APNs endpoint" do
      setup_ios_client(user, client_id: "device-token-1")

      described_class.push(user, payload)

      expect(sandbox_connection).to have_received(:push) do |notification|
        expect(notification.token).to eq("device-token-1")
      end
    end

    it "closes both the production and sandbox connections" do
      setup_ios_client(user)

      described_class.push(user, payload)

      expect(connection).to have_received(:close)
      expect(sandbox_connection).to have_received(:close)
    end

    it "does not open a sandbox connection when every token succeeds on production" do
      allow(connection).to receive(:push).and_return(ok_response)
      setup_ios_client(user)

      described_class.push(user, payload)

      expect(Apnotic::Connection).not_to have_received(:development)
    end
  end
end
