# frozen_string_literal: true

RSpec.describe Jobs::GenerateInvitePersonalization do
  describe "#execute" do
    it "flips each given invite to :bulk_pending once personalized -- the caller is expected to have already claimed them into :drafting" do
      invite_one = Fabricate(:invite, email: "a@nit.ac.in")
      invite_two = Fabricate(:invite, email: "b@nit.ac.in")

      BulkInvitePersonalization::Generator
        .stubs(:personalize)
        .with(invite_one, extra_keywords: nil)
        .returns(subject: "Subject one", body: "Body one")
      BulkInvitePersonalization::Generator
        .stubs(:personalize)
        .with(invite_two, extra_keywords: nil)
        .returns(subject: "Subject two", body: "Body two")

      described_class.new.execute(invite_ids: [invite_one.id, invite_two.id])

      expect(invite_one.reload.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
      expect(invite_one.custom_subject).to eq("Subject one")
      expect(invite_one.custom_message).to eq("Body one")
      expect(invite_two.reload.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
      expect(invite_two.custom_subject).to eq("Subject two")
      # The actual send only happens once Jobs::ProcessBulkInviteEmails later
      # claims it off the bulk_pending queue -- not inline, not here.
      expect(Jobs::InviteEmail.jobs).to be_empty
    end

    it "keeps the invite's existing custom_subject/custom_message when personalization doesn't apply" do
      invite =
        Fabricate(
          :invite,
          custom_subject: "An existing note",
          custom_message: "Looking forward to having you.",
        )

      BulkInvitePersonalization::Generator.stubs(:personalize).returns(nil)

      described_class.new.execute(invite_ids: [invite.id])

      expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
      expect(invite.custom_subject).to eq("An existing note")
      expect(invite.custom_message).to eq("Looking forward to having you.")
    end

    it "marks only the failing invite :skipped, without aborting the rest of the batch" do
      failing = Fabricate(:invite)
      later = Fabricate(:invite)

      BulkInvitePersonalization::Generator
        .stubs(:personalize)
        .with(failing, extra_keywords: nil)
        .raises(BulkInvitePersonalization::Generator::GenerationFailed, "provider outage")
      BulkInvitePersonalization::Generator
        .stubs(:personalize)
        .with(later, extra_keywords: nil)
        .returns(nil)

      described_class.new.execute(invite_ids: [failing.id, later.id])

      expect(failing.reload.emailed_status).to eq(Invite.emailed_status_types[:skipped])
      expect(later.reload.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
    end

    it "forwards extra_keywords to the personalize call" do
      invite = Fabricate(:invite)

      BulkInvitePersonalization::Generator
        .stubs(:personalize)
        .with(invite, extra_keywords: "robotics club")
        .returns(nil)

      described_class.new.execute(invite_ids: [invite.id], extra_keywords: "robotics club")

      expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
    end

    it "nudges ensure_chain! once a slice produces a bulk_pending invite" do
      invite = Fabricate(:invite)
      BulkInvitePersonalization::Generator.stubs(:personalize).returns(nil)

      described_class.new.execute(invite_ids: [invite.id])

      expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(1)
    end

    it "joins an already-running throttle chain instead of starting a second one" do
      invite = Fabricate(:invite)
      BulkInvitePersonalization::Generator.stubs(:personalize).returns(nil)
      Discourse.redis.set(Jobs::ProcessBulkInviteEmails::CHAIN_KEY, 1)

      described_class.new.execute(invite_ids: [invite.id])

      expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
      expect(Jobs::ProcessBulkInviteEmails.jobs).to be_empty
    end

    it "processes more invites than the concurrency cap across multiple thread-batch slices" do
      SiteSetting.bulk_invite_personalization_max_concurrency = 2
      invites = Fabricate.times(5, :invite)
      BulkInvitePersonalization::Generator.stubs(:personalize).returns(nil)

      described_class.new.execute(invite_ids: invites.map(&:id))

      invites.each do |invite|
        expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
      end
    end

    it "does nothing for a blank invite_ids list" do
      expect { described_class.new.execute(invite_ids: []) }.not_to raise_error
      expect(Jobs::ProcessBulkInviteEmails.jobs).to be_empty
    end
  end
end
