# frozen_string_literal: true

RSpec.describe BatchModerationMailer do
  fab!(:to_user, :user)
  fab!(:actor, :user)
  fab!(:target, :user)
  fab!(:group) { Fabricate(:group, full_name: "NIT Trichy · 2024") }

  describe "#action_taken" do
    let(:mail) do
      described_class.action_taken(
        to_user,
        actor: actor,
        target: target,
        action: :suspend,
        reason: "violated batch rules",
      )
    end

    it "renders without raising and includes the reason and profile link" do
      expect(mail.to).to eq([to_user.email])
      expect(mail.body.encoded).to include("violated batch rules")
      expect(mail.body.encoded).to include(target.username)
    end
  end

  describe "#cohort_change" do
    it "renders the joined variant without raising" do
      mail = described_class.cohort_change(to_user, user: target, group: group, joined: true)
      expect(mail.body.encoded).to include(target.username)
      expect(mail.body.encoded).to include(group.full_name)
    end

    it "renders the left variant without raising" do
      mail = described_class.cohort_change(to_user, user: target, group: group, joined: false)
      expect(mail.body.encoded).to include(target.username)
    end
  end

  describe "#status_change" do
    it "renders the granted variant with an actor without raising" do
      mail =
        described_class.status_change(
          to_user,
          actor: actor,
          user: target,
          group: group,
          granted: true,
        )
      expect(mail.body.encoded).to include(actor.username)
      expect(mail.body.encoded).to include(target.username)
      expect(mail.body.encoded).to include(group.full_name)
    end

    it "renders the revoked variant without raising" do
      mail =
        described_class.status_change(
          to_user,
          actor: actor,
          user: target,
          group: group,
          granted: false,
        )
      expect(mail.body.encoded).to include(target.username)
    end

    it "renders the nil-actor (auto-promotion) case without raising" do
      mail =
        described_class.status_change(
          to_user,
          actor: nil,
          user: target,
          group: group,
          granted: true,
        )
      expect(mail.body.encoded).to include(I18n.t("batch_moderation.system_actor"))
    end
  end
end
