# frozen_string_literal: true

RSpec.describe InvitedUserRecordSerializer do
  fab!(:inviter, :user)
  fab!(:redeeming_user) { Fabricate(:user, email: "redeemed-with-this@example.com") }
  fab!(:viewer) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:admin)

  def serialize(scope:, show_emails:)
    ser =
      InvitedUserRecordSerializer.new(
        redeeming_user,
        scope: scope,
        root: false,
        show_emails: show_emails,
      )
    ser.invited_by = inviter
    ser.as_json
  end

  it "includes the account's own email for staff when show_emails is true" do
    json = serialize(scope: Guardian.new(admin), show_emails: true)
    expect(json[:email]).to eq("redeemed-with-this@example.com")
  end

  it "omits the email when show_emails is false, even for staff" do
    json = serialize(scope: Guardian.new(admin), show_emails: false)
    expect(json).not_to include(:email)
  end

  it "omits the email for a viewer who isn't staff or the inviter" do
    json = serialize(scope: Guardian.new(viewer), show_emails: true)
    expect(json).not_to include(:email)
  end

  it "no longer serializes time_read, days_visited, or days_since_created" do
    json = serialize(scope: Guardian.new(admin), show_emails: true)
    expect(json).not_to include(:time_read, :days_visited, :days_since_created)
  end
end
