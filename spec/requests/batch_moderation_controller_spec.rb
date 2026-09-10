# frozen_string_literal: true

RSpec.describe BatchModerationController do
  fab!(:college_field) { Fabricate(:user_field, name: "College", requirement: "optional") }
  fab!(:branch_field) { Fabricate(:user_field, name: "Branch", requirement: "optional") }
  fab!(:batch_field) { Fabricate(:user_field, name: "Batch", requirement: "optional") }
  fab!(:moderator_user, :user)
  fab!(:batchmate, :user)
  fab!(:stranger, :user)

  before do
    SiteSetting.enable_batch_moderation = true
    # Default is 10 -- low enough that both `moderator_user` and `batchmate`
    # (the only two joiners in these specs) would otherwise both get
    # auto-promoted to owner, making them peers `Moderator.can_moderate?`
    # deliberately excludes from moderating each other. `moderator_user` is
    # made an owner explicitly below regardless.
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

  before do
    sync(moderator_user, branch: "CSE", batch: "2024")
    @batch_group = Group.last
    sync(batchmate, branch: "CSE", batch: "2024")
    @batch_group.add_owner(moderator_user)
  end

  describe "#suspend" do
    it "returns 403 for a logged out user" do
      put "/batch-moderation/users/#{batchmate.id}/suspend.json",
          params: {
            reason: "test",
            suspend_until: 3.days.from_now,
          }
      expect(response.status).to eq(403)
    end

    it "allows a batch moderator to suspend a batchmate" do
      sign_in(moderator_user)

      put "/batch-moderation/users/#{batchmate.id}/suspend.json",
          params: {
            reason: "violated batch rules",
            suspend_until: 3.days.from_now,
          }

      expect(response.status).to eq(200)
      expect(batchmate.reload).to be_suspended
    end

    it "forbids suspending a stranger outside the batch group" do
      sign_in(moderator_user)

      put "/batch-moderation/users/#{stranger.id}/suspend.json",
          params: {
            reason: "violated batch rules",
            suspend_until: 3.days.from_now,
          }

      expect(response.status).to eq(403)
      expect(stranger.reload).not_to be_suspended
    end

    it "forbids a non-owner batch member from suspending a batchmate" do
      other_member = Fabricate(:user)
      sync(other_member, branch: "CSE", batch: "2024")
      sign_in(other_member)

      put "/batch-moderation/users/#{batchmate.id}/suspend.json",
          params: {
            reason: "violated batch rules",
            suspend_until: 3.days.from_now,
          }

      expect(response.status).to eq(403)
    end

    it "forbids suspending a fellow batch-group owner (peer)" do
      peer_moderator = Fabricate(:user)
      sync(peer_moderator, branch: "CSE", batch: "2024")
      @batch_group.add_owner(peer_moderator)
      sign_in(moderator_user)

      put "/batch-moderation/users/#{peer_moderator.id}/suspend.json",
          params: {
            reason: "violated batch rules",
            suspend_until: 3.days.from_now,
          }

      expect(response.status).to eq(403)
    end

    it "forbids suspending staff" do
      batchmate.update!(moderator: true)
      sign_in(moderator_user)

      put "/batch-moderation/users/#{batchmate.id}/suspend.json",
          params: {
            reason: "violated batch rules",
            suspend_until: 3.days.from_now,
          }

      expect(response.status).to eq(403)
    end
  end

  describe "#silence" do
    it "allows a batch moderator to silence a batchmate" do
      sign_in(moderator_user)

      put "/batch-moderation/users/#{batchmate.id}/silence.json",
          params: {
            reason: "violated batch rules",
            silenced_till: 3.days.from_now,
          }

      expect(response.status).to eq(200)
      expect(batchmate.reload).to be_silenced
    end

    it "forbids silencing a stranger outside the batch group" do
      sign_in(moderator_user)

      put "/batch-moderation/users/#{stranger.id}/silence.json",
          params: {
            reason: "violated batch rules",
            silenced_till: 3.days.from_now,
          }

      expect(response.status).to eq(403)
      expect(stranger.reload).not_to be_silenced
    end
  end

  describe "#report" do
    it "allows a batch moderator to report a batchmate" do
      sign_in(moderator_user)

      put "/batch-moderation/users/#{batchmate.id}/report.json", params: { reason: "rude in DMs" }

      expect(response.status).to eq(200)
      expect(ReviewableBatchModerationReport.pending.where(target: batchmate).count).to eq(1)
    end

    it "allows reporting a fellow batch-group owner (peer)" do
      peer_moderator = Fabricate(:user)
      sync(peer_moderator, branch: "CSE", batch: "2024")
      @batch_group.add_owner(peer_moderator)
      sign_in(moderator_user)

      put "/batch-moderation/users/#{peer_moderator.id}/report.json",
          params: {
            reason: "rude in DMs",
          }

      expect(response.status).to eq(200)
    end

    it "forbids reporting a stranger outside the batch group" do
      sign_in(moderator_user)

      put "/batch-moderation/users/#{stranger.id}/report.json", params: { reason: "rude" }

      expect(response.status).to eq(403)
    end

    it "forbids an empty reason" do
      sign_in(moderator_user)

      put "/batch-moderation/users/#{batchmate.id}/report.json", params: { reason: "" }

      expect(response.status).to eq(400)
    end

    it "returns 403 for a logged out user" do
      put "/batch-moderation/users/#{batchmate.id}/report.json", params: { reason: "rude" }

      expect(response.status).to eq(403)
    end
  end
end
