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
    it "allows staff" do
      expect(Guardian.new(admin).can_bulk_invite_to_forum?).to eq(true)
    end

    it "denies a regular user who doesn't own a batch group" do
      expect(Guardian.new(regular_user).can_bulk_invite_to_forum?).to eq(false)
    end

    it "allows a batch moderator who owns a batch group" do
      expect(Guardian.new(batch_moderator).can_bulk_invite_to_forum?).to eq(true)
    end
  end
end
