# frozen_string_literal: true

RSpec.describe BatchModeration::GuardianExtension do
  fab!(:batch_moderator, :user)
  fab!(:regular_user, :user)
  fab!(:admin)

  before do
    SiteSetting.enable_batch_moderation = true

    group = Fabricate(:group)
    group.custom_fields[BatchModeration::GroupSync::CUSTOM_FIELD_FLAG] = "t"
    group.save_custom_fields
    group.add_owner(batch_moderator)
  end

  describe "#can_bulk_invite_to_forum?" do
    it "allows staff regardless of the LinkedIn setting" do
      SiteSetting.batch_moderator_linkedin_auth = true
      expect(Guardian.new(admin).can_bulk_invite_to_forum?).to eq(true)
    end

    it "denies a regular user who doesn't own a batch group" do
      expect(Guardian.new(regular_user).can_bulk_invite_to_forum?).to eq(false)
    end

    it "allows a batch moderator when the LinkedIn setting is off" do
      SiteSetting.batch_moderator_linkedin_auth = false
      expect(Guardian.new(batch_moderator).can_bulk_invite_to_forum?).to eq(true)
    end

    it "denies a batch moderator with no connected LinkedIn account when the setting is on" do
      SiteSetting.batch_moderator_linkedin_auth = true
      expect(Guardian.new(batch_moderator).can_bulk_invite_to_forum?).to eq(false)
    end

    it "allows a batch moderator with a connected LinkedIn account when the setting is on" do
      SiteSetting.batch_moderator_linkedin_auth = true
      Fabricate(:user_associated_account, user: batch_moderator, provider_name: "linkedin_oidc")

      expect(Guardian.new(batch_moderator).can_bulk_invite_to_forum?).to eq(true)
    end
  end

  describe "#bulk_invite_needs_linkedin_connection?" do
    it "is false for staff even when the setting is on" do
      SiteSetting.batch_moderator_linkedin_auth = true
      expect(Guardian.new(admin).bulk_invite_needs_linkedin_connection?).to eq(false)
    end

    it "is false for a non-batch-moderator" do
      SiteSetting.batch_moderator_linkedin_auth = true
      expect(Guardian.new(regular_user).bulk_invite_needs_linkedin_connection?).to eq(false)
    end

    it "is true for a batch moderator with no connected LinkedIn account when the setting is on" do
      SiteSetting.batch_moderator_linkedin_auth = true
      expect(Guardian.new(batch_moderator).bulk_invite_needs_linkedin_connection?).to eq(true)
    end

    it "is false for a batch moderator with a connected LinkedIn account" do
      SiteSetting.batch_moderator_linkedin_auth = true
      Fabricate(:user_associated_account, user: batch_moderator, provider_name: "linkedin_oidc")

      expect(Guardian.new(batch_moderator).bulk_invite_needs_linkedin_connection?).to eq(false)
    end
  end
end
