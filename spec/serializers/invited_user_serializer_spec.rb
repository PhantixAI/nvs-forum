# frozen_string_literal: true

RSpec.describe InvitedUserSerializer do
  fab!(:inviter, :user)
  fab!(:redeeming_user) { Fabricate(:user, email: "redeemed-with-this@example.com") }
  fab!(:viewer) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:admin)

  fab!(:invite) { Fabricate(:invite, invited_by: inviter, email: "invited-target@example.com") }
  fab!(:invited_user) { Fabricate(:invited_user, invite: invite, user: redeeming_user) }

  def serialize(scope:, show_emails:)
    InvitedUserSerializer.new(
      invited_user,
      scope: scope,
      root: false,
      show_emails: show_emails,
    ).as_json
  end

  it "includes the invite's own target email and the redeeming account's email for staff" do
    json = serialize(scope: Guardian.new(admin), show_emails: true)

    expect(json[:email]).to eq("invited-target@example.com")
    expect(json[:user][:email]).to eq("redeemed-with-this@example.com")
  end

  it "includes both emails for the inviter viewing their own invites" do
    json = serialize(scope: Guardian.new(inviter), show_emails: true)

    expect(json[:email]).to eq("invited-target@example.com")
    expect(json[:user][:email]).to eq("redeemed-with-this@example.com")
  end

  it "omits both emails when show_emails is false" do
    json = serialize(scope: Guardian.new(admin), show_emails: false)

    expect(json).not_to include(:email)
    expect(json[:user]).not_to include(:email)
  end

  it "omits both emails for a viewer who isn't staff or the inviter" do
    json = serialize(scope: Guardian.new(viewer), show_emails: true)

    expect(json).not_to include(:email)
    expect(json[:user]).not_to include(:email)
  end

  it "omits the invite's own email, but still includes the account email, for a redeemed link invite" do
    link_invite = Fabricate(:invite, invited_by: inviter, email: nil, max_redemptions_allowed: 5)
    link_invited_user = Fabricate(:invited_user, invite: link_invite, user: redeeming_user)

    json =
      InvitedUserSerializer.new(
        link_invited_user,
        scope: Guardian.new(admin),
        root: false,
        show_emails: true,
      ).as_json

    expect(json[:email]).to eq(nil)
    expect(json[:invite_source]).to eq("link")
    expect(json[:user][:email]).to eq("redeemed-with-this@example.com")
  end
end
