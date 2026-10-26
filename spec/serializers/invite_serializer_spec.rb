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
        :recipient_keywords,
        :allow_any_email,
        :source_url,
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

  describe "emailed/delivery_status for allow_any_email invites" do
    fab!(:user)

    it "includes emailed and delivery_status for a sent allow_any_email invite, using description as the recipient" do
      # Mirrors Jobs::BulkInvite#send_invite: email: nil, description: the
      # real address, emailed_status explicitly moved off :not_required once
      # actually sent.
      invite =
        Invite.generate(
          user,
          email: nil,
          description: "asharani@ee.nits.ac.in",
          allow_any_email: true,
          max_redemptions_allowed: 1,
        )
      invite.update_column(:emailed_status, Invite.emailed_status_types[:sent])

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:emailed]).to eq(true)
      expect(json[:delivery_status]).to eq("sent")
    end

    it "omits emailed and delivery_status for a never-emailed invite link with no description" do
      invite = Invite.generate(user, email: nil, max_redemptions_allowed: 1)

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json).not_to include(:emailed, :delivery_status)
    end
  end

  describe "draft invites" do
    fab!(:user)

    it "reports emailed as false for a review invite, unlike an ordinary never-emailed invite link" do
      invite =
        Invite.generate(
          user,
          email: "draftee@example.com",
          emailed_status: Invite.emailed_status_types[:review],
        )

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:emailed]).to eq(false)
      expect(json[:delivery_status]).to eq("review")
    end

    it "serializes recipient_keywords when the viewer can see invite details" do
      invite =
        Invite.generate(
          user,
          email: "draftee2@example.com",
          recipient_keywords: "robotics, machine learning",
        )

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:recipient_keywords]).to eq("robotics, machine learning")
    end

    it "serializes allow_any_email when the viewer can see invite details" do
      invite = Invite.generate(user, email: "draftee3@example.com", allow_any_email: true)

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:allow_any_email]).to eq(true)
    end

    it "serializes source_url when the viewer can see invite details" do
      invite =
        Invite.generate(
          user,
          email: "draftee4@example.com",
          source_url: "https://example.edu/students",
        )

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:source_url]).to eq("https://example.edu/students")
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

  describe "#draft_preview_available" do
    fab!(:user)
    fab!(:admin)
    fab!(:moderator)
    fab!(:invite) do
      Fabricate(
        :invite,
        invited_by: user,
        emailed_status: Invite.emailed_status_types[:bulk_pending],
      )
    end

    it "is true for an admin viewing a :bulk_pending invite" do
      json = InviteSerializer.new(invite, scope: Guardian.new(admin), root: false).as_json

      expect(json[:draft_preview_available]).to eq(true)
    end

    it "is true for an admin viewing a :sending invite" do
      invite.update_column(:emailed_status, Invite.emailed_status_types[:sending])

      json = InviteSerializer.new(invite, scope: Guardian.new(admin), root: false).as_json

      expect(json[:draft_preview_available]).to eq(true)
    end

    it "is false for a :review invite (content not finalized yet)" do
      invite.update_column(:emailed_status, Invite.emailed_status_types[:review])

      json = InviteSerializer.new(invite, scope: Guardian.new(admin), root: false).as_json

      expect(json[:draft_preview_available]).to eq(false)
    end

    it "is false for an already-:sent invite" do
      invite.update_column(:emailed_status, Invite.emailed_status_types[:sent])

      json = InviteSerializer.new(invite, scope: Guardian.new(admin), root: false).as_json

      expect(json[:draft_preview_available]).to eq(false)
    end

    it "is omitted entirely for a moderator, even though moderators can send drafts elsewhere on this page" do
      json = InviteSerializer.new(invite, scope: Guardian.new(moderator), root: false).as_json

      expect(json).not_to include(:draft_preview_available)
    end

    it "is omitted entirely for a plain user" do
      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json).not_to include(:draft_preview_available)
    end
  end

  describe "#drafting" do
    fab!(:user)
    fab!(:invite) do
      Fabricate(:invite, invited_by: user, emailed_status: Invite.emailed_status_types[:drafting])
    end

    it "is true for a :drafting invite, even though #delivery_status itself still reads \"review\" for it" do
      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:drafting]).to eq(true)
      expect(json[:delivery_status]).to eq("review")
    end

    it "is false for a plain :review invite" do
      invite.update_column(:emailed_status, Invite.emailed_status_types[:review])

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:drafting]).to eq(false)
    end

    it "is false once the invite moves past drafting (e.g. :bulk_pending)" do
      invite.update_column(:emailed_status, Invite.emailed_status_types[:bulk_pending])

      json = InviteSerializer.new(invite, scope: Guardian.new(user), root: false).as_json

      expect(json[:drafting]).to eq(false)
    end
  end
end
