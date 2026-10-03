# frozen_string_literal: true

RSpec.describe Jobs::ResendInvitesWithKeywords do
  describe "#execute" do
    it "regenerates custom_subject/custom_message with the given keywords and resends each invite" do
      invite = Fabricate(:invite, email: "student@nit.ac.in")

      BulkInvitePersonalization::Generator
        .stubs(:personalize)
        .with(invite, extra_keywords: "robotics club")
        .returns(subject: "A fresh subject", body: "A freshly generated note.")

      described_class.new.execute(invite_ids: [invite.id], extra_keywords: "robotics club")

      expect(invite.reload.custom_subject).to eq("A fresh subject")
      expect(invite.custom_message).to eq("A freshly generated note.")
      expect(Jobs::InviteEmail.jobs.size).to eq(1)
      expect(Jobs::InviteEmail.jobs.first["args"].first["invite_id"]).to eq(invite.id)
    end

    it "keeps the invite's existing custom_message when personalization is unavailable" do
      invite = Fabricate(:invite, custom_message: "Looking forward to having you.")

      BulkInvitePersonalization::Generator.stubs(:personalize).returns(nil)

      described_class.new.execute(invite_ids: [invite.id], extra_keywords: "robotics club")

      expect(invite.reload.custom_message).to eq("Looking forward to having you.")
      expect(Jobs::InviteEmail.jobs.size).to eq(1)
    end

    it "skips an invite whose personalization fails without sending it, and keeps processing the rest" do
      failing = Fabricate(:invite)
      later = Fabricate(:invite)

      BulkInvitePersonalization::Generator
        .stubs(:personalize)
        .with(failing, extra_keywords: "x")
        .raises(BulkInvitePersonalization::Generator::GenerationFailed, "provider outage")
      BulkInvitePersonalization::Generator
        .stubs(:personalize)
        .with(later, extra_keywords: "x")
        .returns(nil)

      described_class.new.execute(invite_ids: [failing.id, later.id], extra_keywords: "x")

      expect(failing.reload.emailed_status).to eq(Invite.emailed_status_types[:skipped])
      expect(Jobs::InviteEmail.jobs.map { |job| job["args"].first["invite_id"] }).to eq([later.id])
    end
  end
end
