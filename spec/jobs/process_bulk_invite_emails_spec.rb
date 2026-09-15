# frozen_string_literal: true

RSpec.describe Jobs::ProcessBulkInviteEmails do
  before do
    SiteSetting.bulk_invite_email_delay_min_seconds = 5
    SiteSetting.bulk_invite_email_delay_max_seconds = 15
  end

  describe "#execute" do
    it "does nothing when there are no pending invites" do
      described_class.new.execute({})

      expect(Jobs::InviteEmail.jobs.size).to eq(0)
      expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(0)
    end

    it "processes exactly one pending invite per run, leaving the rest pending" do
      invites =
        3.times.map do
          Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])
        end

      described_class.new.execute({})

      reloaded = invites.map(&:reload)
      sending = reloaded.select { |i| i.emailed_status == Invite.emailed_status_types[:sending] }
      still_pending =
        reloaded.select { |i| i.emailed_status == Invite.emailed_status_types[:bulk_pending] }

      expect(sending.length).to eq(1)
      expect(still_pending.length).to eq(2)
      expect(Jobs::InviteEmail.jobs.size).to eq(1)
    end

    it "picks the oldest pending invite first" do
      older = Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])
      Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])

      described_class.new.execute({})

      expect(older.reload.emailed_status).to eq(Invite.emailed_status_types[:sending])
    end

    it "reschedules itself with a delay within the configured bounds" do
      Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])

      freeze_time do
        described_class.new.execute({})

        job = Jobs::ProcessBulkInviteEmails.jobs.last
        scheduled_at = job["at"]

        expect(scheduled_at).to be >=
          Time.now.to_f + SiteSetting.bulk_invite_email_delay_min_seconds
        expect(scheduled_at).to be <=
          Time.now.to_f + SiteSetting.bulk_invite_email_delay_max_seconds
      end
    end

    it "does not reschedule itself when the pending pool is empty" do
      described_class.new.execute({})

      expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(0)
    end

    it "sets custom_message from AI personalization when it returns text" do
      invite = Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])

      BulkInvitePersonalization::Generator.stubs(:personalize).returns("A personalized note.")

      described_class.new.execute({})

      expect(invite.reload.custom_message).to eq("A personalized note.")
    end

    it "leaves custom_message blank when personalization is unavailable" do
      invite = Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])

      BulkInvitePersonalization::Generator.stubs(:personalize).returns(nil)

      described_class.new.execute({})

      expect(invite.reload.custom_message).to eq(nil)
      expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:sending])
    end
  end
end
