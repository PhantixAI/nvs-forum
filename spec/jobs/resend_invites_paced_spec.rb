# frozen_string_literal: true

RSpec.describe Jobs::ResendInvitesPaced do
  describe "#execute" do
    it "resends the invite exactly as it already is, with no personalization call" do
      freeze_time
      invite =
        Fabricate(
          :invite,
          email: "student@nit.ac.in",
          custom_subject: "a previously AI-generated subject",
          custom_message: "a previously AI-personalized note",
        )
      invite.update!(expires_at: 2.days.from_now)

      BulkInvitePersonalization::Generator.expects(:personalize).never

      described_class.new.execute(invite_id: invite.id)

      expect(invite.reload.expires_at).to eq_time(SiteSetting.invite_expiry_days.days.from_now)
      expect(invite.custom_subject).to eq("a previously AI-generated subject")
      expect(invite.custom_message).to eq("a previously AI-personalized note")
      expect(Jobs::InviteEmail.jobs.map { |job| job["args"].first["invite_id"] }).to eq([invite.id])
    end

    it "does nothing when the invite no longer exists" do
      expect { described_class.new.execute(invite_id: -1) }.not_to raise_error
      expect(Jobs::InviteEmail.jobs).to be_empty
    end
  end
end
