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

    it "keeps a note the inviter wrote when personalization is unavailable" do
      invite =
        Fabricate(
          :invite,
          emailed_status: Invite.emailed_status_types[:bulk_pending],
          custom_message: "Looking forward to having you.",
        )

      BulkInvitePersonalization::Generator.stubs(:personalize).returns(nil)

      described_class.new.execute({})

      expect(invite.reload.custom_message).to eq("Looking forward to having you.")
    end

    it "skips an invite whose personalization fails, without sending it, and keeps the chain going" do
      invite = Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])
      later_invite = Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])

      BulkInvitePersonalization::Generator.stubs(:personalize).raises(
        BulkInvitePersonalization::Generator::GenerationFailed,
        "spend cap exceeded",
      )

      described_class.new.execute({})

      expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:skipped])
      expect(invite.delivery_status).to eq("skipped")
      expect(Jobs::InviteEmail.jobs.size).to eq(0)
      expect(later_invite.reload.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
      expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(1)
    end

    it "does not retry a skipped invite on the next run" do
      invite = Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])

      BulkInvitePersonalization::Generator.stubs(:personalize).raises(
        BulkInvitePersonalization::Generator::GenerationFailed,
        "spend cap exceeded",
      )

      described_class.new.execute({})
      Jobs::ProcessBulkInviteEmails.jobs.clear
      described_class.new.execute({})

      expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:skipped])
      expect(Jobs::InviteEmail.jobs.size).to eq(0)
    end

    # Covers an unexpected error elsewhere in #deliver, which #execute's own
    # rescue still handles.
    it "moves an invite that fails to send to pending and keeps the chain going" do
      invite = Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])
      later_invite = Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])

      BulkInvitePersonalization::Generator.stubs(:personalize).raises(StandardError, "boom")

      described_class.new.execute({})

      expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:pending])
      expect(later_invite.reload.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
      expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(1)
    end

    it "stamps the claim time so time spent sending can be measured" do
      freeze_time
      invite =
        Fabricate(
          :invite,
          emailed_status: Invite.emailed_status_types[:bulk_pending],
          updated_at: 3.days.ago,
        )

      described_class.new.execute({})

      expect(invite.reload.updated_at).to eq_time(Time.zone.now)
    end

    it "requeues an invite stuck in sending after its worker died" do
      stuck = Fabricate(:invite, emailed_status: Invite.emailed_status_types[:sending])
      stuck.update_columns(updated_at: 2.hours.ago)

      described_class.new.execute({})

      expect(Jobs::InviteEmail.jobs.size).to eq(1)
      expect(Jobs::InviteEmail.jobs.first["args"].first["invite_id"]).to eq(stuck.id)
    end

    it "leaves an invite that only just entered sending alone" do
      Fabricate(:invite, emailed_status: Invite.emailed_status_types[:sending])

      described_class.new.execute({})

      expect(Jobs::InviteEmail.jobs.size).to eq(0)
    end

    it "clears the chain key when nothing is pending" do
      Discourse.redis.set(described_class::CHAIN_KEY, 1)

      described_class.new.execute({})

      expect(Discourse.redis.get(described_class::CHAIN_KEY)).to eq(nil)
    end

    it "starts a new chain if an invite arrived as the old one ended" do
      Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])
      Discourse.redis.set(described_class::CHAIN_KEY, 1)
      described_class.any_instance.stubs(:claim_next_pending_invite).returns(nil)

      described_class.new.execute({})

      expect(Discourse.redis.get(described_class::CHAIN_KEY)).to be_present
      expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(1)
    end

    it "keeps the chain key alive while it has work" do
      Fabricate(:invite, emailed_status: Invite.emailed_status_types[:bulk_pending])

      described_class.new.execute({})

      expect(Discourse.redis.ttl(described_class::CHAIN_KEY)).to be > 0
    end
  end

  describe ".ensure_chain!" do
    it "enqueues one job however many starters call it" do
      3.times { described_class.ensure_chain! }

      expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(1)
    end

    it "returns whether it started a chain" do
      expect(described_class.ensure_chain!).to eq(true)
      expect(described_class.ensure_chain!).to eq(false)
    end

    it "lets a lapsed chain be replaced" do
      described_class.ensure_chain!
      Discourse.redis.del(described_class::CHAIN_KEY)

      expect(described_class.ensure_chain!).to eq(true)
      expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(2)
    end
  end
end
