# frozen_string_literal: true

# A site without the Apple auth plugin has none of the Apple key settings, so
# APNs must be a silent no-op rather than failing every push job.
RSpec.describe ApnsPushNotificationPusher do
  fab!(:user)

  before do
    if SiteSetting.respond_to?(:apple_pem)
      skip "only applies when the discourse-apple-auth plugin is not loaded"
    end
  end

  it "is not configured" do
    expect(described_class.configured?).to eq(false)
  end

  it "does nothing for a user with an ios client" do
    client = Fabricate(:user_api_key_client, application_name: "TestApp")
    Fabricate(
      :user_api_key,
      user: user,
      scopes: [UserApiKeyScope.new(name: "notifications")],
      push_url: "ios",
      user_api_key_client_id: client.id,
    )
    Apnotic::Connection.expects(:new).never

    expect {
      described_class.push(user, { notification_type: 1, excerpt: "Hello" })
    }.not_to raise_error
  end
end
