# frozen_string_literal: true

RSpec.describe BatchModeration::Moderator do
  fab!(:college_field) { Fabricate(:user_field, name: "College", requirement: "optional") }
  fab!(:branch_field) { Fabricate(:user_field, name: "Branch", requirement: "optional") }
  fab!(:batch_field) { Fabricate(:user_field, name: "Batch", requirement: "optional") }
  fab!(:actor, :user)
  fab!(:target, :user)

  before do
    SiteSetting.enable_batch_moderation = true
    # Default is 10 -- low enough that joiners in these specs would otherwise
    # get auto-promoted to owner, contradicting tests that assert a "regular
    # member" (non-owner) scenario. Every test that needs an owner sets one
    # explicitly via `make_owner!`, so auto-promotion is disabled entirely.
    SiteSetting.batch_moderation_auto_promote_count = 0
  end

  def set_fields(user, branch:, batch:)
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{college_field.id}"] = "MNIT Jaipur"
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{branch_field.id}"] = branch
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{batch_field.id}"] = batch
    user.save_custom_fields(true, run_validations: false)
  end

  def sync(user, branch:, batch:)
    set_fields(user, branch: branch, batch: batch)
    BatchModeration::GroupSync.sync(user)
  end

  def make_owner!(user, group)
    group.add_owner(user)
  end

  describe ".can_moderate?" do
    it "is false when targeting oneself" do
      sync(actor, branch: "CSE", batch: "2024")
      make_owner!(actor, Group.last)

      expect(described_class.can_moderate?(actor, actor)).to eq(false)
    end

    it "is false when the site setting is disabled" do
      sync(actor, branch: "CSE", batch: "2024")
      sync(target, branch: "CSE", batch: "2024")
      make_owner!(actor, Group.last)
      SiteSetting.enable_batch_moderation = false

      expect(described_class.can_moderate?(actor, target)).to eq(false)
    end

    it "is false when actor and target do not share a batch group" do
      sync(actor, branch: "CSE", batch: "2024")
      actor_group = Group.last
      sync(target, branch: "ECE", batch: "2025")
      make_owner!(actor, actor_group)

      expect(described_class.can_moderate?(actor, target)).to eq(false)
    end

    it "is false when actor shares the group but is not an owner" do
      sync(actor, branch: "CSE", batch: "2024")
      sync(target, branch: "CSE", batch: "2024")

      expect(described_class.can_moderate?(actor, target)).to eq(false)
    end

    it "is true when actor owns a shared batch group and target is a regular member" do
      sync(actor, branch: "CSE", batch: "2024")
      sync(target, branch: "CSE", batch: "2024")
      make_owner!(actor, Group.last)

      expect(described_class.can_moderate?(actor, target)).to eq(true)
    end

    it "is false when the target is staff" do
      sync(actor, branch: "CSE", batch: "2024")
      target.update!(moderator: true)
      sync(target, branch: "CSE", batch: "2024")
      make_owner!(actor, Group.last)

      expect(described_class.can_moderate?(actor, target)).to eq(false)
    end

    it "is false when the target is also an owner of the same group (peer)" do
      sync(actor, branch: "CSE", batch: "2024")
      sync(target, branch: "CSE", batch: "2024")
      group = Group.last
      make_owner!(actor, group)
      make_owner!(target, group)

      expect(described_class.can_moderate?(actor, target)).to eq(false)
    end
  end

  describe ".can_report?" do
    it "is true when the target is also an owner of the same group (peer)" do
      sync(actor, branch: "CSE", batch: "2024")
      sync(target, branch: "CSE", batch: "2024")
      group = Group.last
      make_owner!(actor, group)
      make_owner!(target, group)

      expect(described_class.can_report?(actor, target)).to eq(true)
    end

    it "is true for a regular batchmate" do
      sync(actor, branch: "CSE", batch: "2024")
      sync(target, branch: "CSE", batch: "2024")
      make_owner!(actor, Group.last)

      expect(described_class.can_report?(actor, target)).to eq(true)
    end

    it "is false when actor and target do not share a batch group" do
      sync(actor, branch: "CSE", batch: "2024")
      actor_group = Group.last
      sync(target, branch: "ECE", batch: "2025")
      make_owner!(actor, actor_group)

      expect(described_class.can_report?(actor, target)).to eq(false)
    end

    it "is false for reporting oneself" do
      sync(actor, branch: "CSE", batch: "2024")
      make_owner!(actor, Group.last)

      expect(described_class.can_report?(actor, actor)).to eq(false)
    end

    it "is false when the target is staff" do
      sync(actor, branch: "CSE", batch: "2024")
      target.update!(moderator: true)
      sync(target, branch: "CSE", batch: "2024")
      make_owner!(actor, Group.last)

      expect(described_class.can_report?(actor, target)).to eq(false)
    end
  end
end
