# frozen_string_literal: true

RSpec.describe ReviewableBatchModerationReport do
  fab!(:actor, :user)
  fab!(:target, :user)
  fab!(:admin)

  describe ".report!" do
    it "creates a pending reviewable targeting the reported user" do
      reviewable = described_class.report!(actor: actor, target: target, reason: "rude in DMs")

      expect(reviewable).to be_pending
      expect(reviewable.target).to eq(target)
      expect(reviewable.created_by).to eq(actor)
      expect(reviewable.payload["reason"]).to eq("rude in DMs")
      expect(reviewable.reviewable_by_moderator).to eq(true)
    end

    it "does not create a duplicate pending reviewable for the same target" do
      described_class.report!(actor: actor, target: target, reason: "first report")

      expect {
        described_class.report!(actor: actor, target: target, reason: "second report")
      }.not_to change { described_class.count }
    end
  end

  describe "repeat reports" do
    fab!(:other_moderator, :user)

    it "keeps every report and shows the newest reason" do
      described_class.report!(actor: actor, target: target, reason: "first report")
      reviewable =
        described_class.report!(actor: other_moderator, target: target, reason: "second report")

      expect(reviewable.payload["reason"]).to eq("second report")
      expect(reviewable.reports.map { |report| report["reporter_username"] }).to eq(
        [actor.username, other_moderator.username],
      )
      expect(reviewable.reports.map { |report| report["reason"] }).to eq(
        ["first report", "second report"],
      )
    end

    it "reopens a resolved report with the new reporter's reason" do
      reviewable = described_class.report!(actor: actor, target: target, reason: "spam")
      reviewable.perform(admin, :disagree_report)

      reopened =
        described_class.report!(actor: other_moderator, target: target, reason: "harassment")

      expect(reopened).to be_pending
      expect(reopened.payload["reason"]).to eq("harassment")
      expect(reopened.reports.size).to eq(2)
    end
  end

  describe "#perform_agree_report" do
    it "approves the reviewable" do
      reviewable = described_class.report!(actor: actor, target: target, reason: "spam")

      result = reviewable.perform(admin, :agree_report)

      expect(result.transition_to).to eq(:approved)
    end
  end

  describe "#perform_disagree_report" do
    it "rejects the reviewable" do
      reviewable = described_class.report!(actor: actor, target: target, reason: "spam")

      result = reviewable.perform(admin, :disagree_report)

      expect(result.transition_to).to eq(:rejected)
    end
  end
end
