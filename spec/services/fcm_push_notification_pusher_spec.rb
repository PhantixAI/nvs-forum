# frozen_string_literal: true

RSpec.describe FcmPushNotificationPusher do
  fab!(:user)
  fab!(:post)

  let(:payload) do
    {
      notification_type: 1,
      post_url: "/t/#{post.topic_id}/#{post.post_number}",
      excerpt: "Hello you",
    }
  end

  let(:service_account) do
    {
      project_id: "test-project",
      client_email: "fcm@test-project.iam.gserviceaccount.com",
      private_key: OpenSSL::PKey::RSA.new(2048).to_pem,
    }.to_json
  end

  def setup_android_client(user, client_id: SecureRandom.hex)
    client = Fabricate(:user_api_key_client, client_id: client_id, application_name: "TestApp")
    Fabricate(
      :user_api_key,
      user: user,
      scopes: ["notifications"].map { |name| UserApiKeyScope.new(name: name) },
      push_url: "android",
      user_api_key_client_id: client.id,
    )
  end

  before do
    SiteSetting.fcm_service_account_json = service_account
    described_class.instance_variable_set(:@service_account, nil)
    Discourse.cache.delete(described_class::ACCESS_TOKEN_CACHE_KEY)

    stub_request(:post, "https://oauth2.googleapis.com/token").to_return(
      status: 200,
      body: { access_token: "test-access-token" }.to_json,
    )
  end

  it "does nothing when no android clients exist" do
    stub =
      stub_request(
        :post,
        "https://fcm.googleapis.com/v1/projects/test-project/messages:send",
      ).to_return(status: 200)

    described_class.push(user, payload)
    expect(stub).not_to have_been_requested
  end

  it "does nothing when fcm_service_account_json is blank" do
    SiteSetting.fcm_service_account_json = ""
    setup_android_client(user)

    stub =
      stub_request(
        :post,
        "https://fcm.googleapis.com/v1/projects/test-project/messages:send",
      ).to_return(status: 200)

    described_class.push(user, payload)
    expect(stub).not_to have_been_requested
  end

  it "sends an FCM message with the notification title, body and url" do
    setup_android_client(user, client_id: "device-token-1")
    body = nil

    stub_request(:post, "https://fcm.googleapis.com/v1/projects/test-project/messages:send")
      .with(headers: { "Authorization" => "Bearer test-access-token" })
      .to_return do |request|
        body = JSON.parse(request.body)
        { status: 200 }
      end

    described_class.push(user, payload)

    expect(body["message"]["token"]).to eq("device-token-1")
    expect(body["message"]["notification"]["body"]).to eq("Hello you")
    expect(body["message"]["data"]["discourse_url"]).to include(
      "/t/#{post.topic_id}/#{post.post_number}",
    )
  end

  it "sends a separate message per registered android client" do
    setup_android_client(user, client_id: "device-token-1")
    setup_android_client(user, client_id: "device-token-2")

    stub =
      stub_request(
        :post,
        "https://fcm.googleapis.com/v1/projects/test-project/messages:send",
      ).to_return(status: 200)

    described_class.push(user, payload)

    expect(stub).to have_been_requested.twice
  end

  it "ignores ios clients" do
    client = Fabricate(:user_api_key_client, application_name: "TestApp")
    Fabricate(
      :user_api_key,
      user: user,
      scopes: ["notifications"].map { |name| UserApiKeyScope.new(name: name) },
      push_url: "ios",
      user_api_key_client_id: client.id,
    )

    stub =
      stub_request(
        :post,
        "https://fcm.googleapis.com/v1/projects/test-project/messages:send",
      ).to_return(status: 200)

    described_class.push(user, payload)
    expect(stub).not_to have_been_requested
  end
end
