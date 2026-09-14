# frozen_string_literal: true

RSpec.describe ReviewableBulkInvite do
  fab!(:actor, :user)
  fab!(:admin)

  let(:invites) { [{ "email" => "new-member@example.com", "topic_id" => "1" }] }
  let(:raw_csv) { "email,topic_id\nnew-member@example.com,1\n" }

  describe ".submit!" do
    it "creates a pending reviewable holding both the parsed invites and the raw csv" do
      reviewable = described_class.submit!(actor: actor, invites: invites, raw_csv: raw_csv)

      expect(reviewable).to be_pending
      expect(reviewable.created_by).to eq(actor)
      expect(reviewable.payload["invites"]).to eq(invites)
      expect(reviewable.payload["raw_csv"]).to eq(raw_csv)
      expect(reviewable.reviewable_by_moderator).to eq(true)
    end
  end

  describe "#perform_approve_bulk_invite" do
    it "enqueues the bulk invite job for the original submitter and approves the reviewable" do
      reviewable = described_class.submit!(actor: actor, invites: invites, raw_csv: raw_csv)

      result = reviewable.perform(admin, :approve_bulk_invite)

      expect(result.transition_to).to eq(:approved)
      job_args = Jobs::BulkInvite.jobs.last["args"].first
      expect(job_args["invites"]).to eq(invites)
      expect(job_args["current_user_id"]).to eq(actor.id)
    end
  end

  describe "#perform_reject_bulk_invite" do
    it "rejects the reviewable and notifies the submitter without enqueuing anything" do
      reviewable = described_class.submit!(actor: actor, invites: invites, raw_csv: raw_csv)

      result = nil
      expect { result = reviewable.perform(admin, :reject_bulk_invite) }.to not_change {
        Jobs::BulkInvite.jobs.size
      }.and change { Topic.where(archetype: Archetype.private_message).count }

      expect(result.transition_to).to eq(:rejected)
      pm = Topic.where(archetype: Archetype.private_message).last
      expect(pm.title).to eq(
        I18n.t("system_messages.reviewable_bulk_invite_rejected.subject_template"),
      )
      expect(pm.topic_allowed_users.pluck(:user_id)).to include(actor.id)
    end
  end
end
