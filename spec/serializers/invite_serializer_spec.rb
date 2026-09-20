# frozen_string_literal: true

RSpec.describe InviteSerializer do
  describe "#as_json" do
    fab!(:user)
    fab!(:viewer) { Fabricate(:user, trust_level: TrustLevel[2]) }
    fab!(:group)
    fab!(:private_category) { Fabricate(:private_category, group: group) }
    fab!(:private_topic) { Fabricate(:topic, category: private_category) }

    it "hides sensitive fields without permission to see invite details" do
      invite =
        Fabricate(
          :invite,
          invited_by: user,
          description: "private invite note",
          custom_message: "private invite message",
        )

      json =
        InviteSerializer.new(
          invite,
          scope: Guardian.new(viewer),
          root: false,
          show_emails: true,
        ).as_json

      expect(json).not_to include(
        :invite_key,
        :link,
        :description,
        :email,
        :domain,
        :emailed,
        :delivery_status,
        :max_redemptions_allowed,
        :redemption_count,
        :custom_message,
        :topics,
        :groups,
      )
    end

    it "filters topics by guardian visibility" do
      invite = Fabricate(:invite, invited_by: user)
      TopicInvite.create!(invite: invite, topic: private_topic)

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:topics]).to eq([])
    end
  end

  describe "#delivery_status" do
    fab!(:user)
    fab!(:invite) do
      Fabricate(
        :invite,
        invited_by: user,
        email: "invitee@example.com",
        emailed_status: Invite.emailed_status_types[:sent],
      )
    end

    it "falls back to querying for the EmailLog when none is preloaded" do
      Fabricate(:email_log, invite_id: invite.id, email_type: "invite", bounced: true)

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:delivery_status]).to eq("bounced")
    end

    it "uses a preloaded EmailLog passed via email_logs_by_invite_id, avoiding a query" do
      email_log = Fabricate(:email_log, invite_id: invite.id, email_type: "invite", bounced: true)

      json =
        InviteSerializer.new(
          invite,
          scope: Guardian.new(user),
          root: false,
          email_logs_by_invite_id: {
            invite.id => email_log,
          },
        ).as_json

      expect(json[:delivery_status]).to eq("bounced")
    end

    it "treats a missing entry in the preloaded hash as no EmailLog, not as unloaded" do
      Fabricate(:email_log, invite_id: invite.id, email_type: "invite", bounced: true)

      json =
        InviteSerializer.new(
          invite,
          scope: Guardian.new(user),
          root: false,
          email_logs_by_invite_id: {
          },
        ).as_json

      expect(json[:delivery_status]).to eq("sent")
    end
  end

  describe "#can_delete_invite" do
    fab!(:user)
    fab!(:admin)
    fab!(:moderator)
    fab!(:invite_from_user) { Fabricate(:invite, invited_by: user) }
    fab!(:invite_from_moderator) { Fabricate(:invite, invited_by: moderator) }

    it "returns true for admin" do
      serializer = InviteSerializer.new(invite_from_user, scope: Guardian.new(admin), root: false)

      expect(serializer.as_json[:can_delete_invite]).to eq(true)
    end

    it "returns false for moderator" do
      serializer =
        InviteSerializer.new(invite_from_user, scope: Guardian.new(moderator), root: false)

      expect(serializer.as_json[:can_delete_invite]).to eq(false)
    end

    it "returns true for inviter" do
      serializer = InviteSerializer.new(invite_from_user, scope: Guardian.new(user), root: false)

      expect(serializer.as_json[:can_delete_invite]).to eq(true)
    end

    it "returns false for plain user" do
      serializer =
        InviteSerializer.new(invite_from_moderator, scope: Guardian.new(user), root: false)

      expect(serializer.as_json[:can_delete_invite]).to eq(false)
    end
  end
end
