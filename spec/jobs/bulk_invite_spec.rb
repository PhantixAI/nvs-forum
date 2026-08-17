# frozen_string_literal: true

RSpec.describe Jobs::BulkInvite do
  describe "#execute" do
    fab!(:user)
    fab!(:admin)
    fab!(:east_coast_user)
    fab!(:group1) { Fabricate(:group, name: "group1") }
    fab!(:group2) { Fabricate(:group, name: "group2") }
    fab!(:topic)
    let(:staged_user) { Fabricate(:user, staged: true, active: false) }
    let(:email) { "test@discourse.org" }
    let(:invites) do
      [
        { email: user.email },
        { email: staged_user.email },
        { email: "test2@discourse.org" },
        { email: "test@discourse.org", groups: "GROUP1;group2", topic_id: topic.id },
        { email: "invalid" },
      ]
    end

    def parse_skipped_and_failed_emails(input)
      skipped_invites_emails = input[/Skipped Invites for Emails?:\s+``` text\n(.+?)\n```/m, 1]
      failed_invites_emails = input[/Failed Invites for Emails?:\s+``` text\n(.+?)\n```/m, 1]

      { skipped_invites: skipped_invites_emails, failed_invites: failed_invites_emails }
    end

    it "raises an error when the invites array is missing" do
      expect { Jobs::BulkInvite.new.execute(current_user_id: user.id) }.to raise_error(
        Discourse::InvalidParameters,
        /invites/,
      )
    end

    it "raises an error when current_user_id is not valid" do
      expect { Jobs::BulkInvite.new.execute(invites: invites) }.to raise_error(
        Discourse::InvalidParameters,
        /current_user_id/,
      )
    end

    it "creates the right invites" do
      described_class.new.execute(current_user_id: admin.id, invites: invites)

      expect(Invite.exists?(email: staged_user.email)).to eq(true)
      expect(Invite.exists?(email: "test2@discourse.org")).to eq(true)

      invite = Invite.last
      expect(invite.email).to eq(email)
      expect(invite.invited_groups.pluck(:group_id)).to contain_exactly(group1.id, group2.id)
      expect(invite.topic_invites.pluck(:topic_id)).to contain_exactly(topic.id)

      post = Post.last
      expect(post.raw).to include("3 invites")
      expect(post.raw).to include("1 skipped")
      expect(post.raw).to include("0 warning")
      expect(post.raw).to include("1 error")
    end

    it "handles daylight savings time correctly" do
      # EDT (-04:00) transitions to EST (-05:00) on the first Sunday in November.
      # Freeze time to the last Day of October, so that the creation and expiration date will be in different time zones.
      Time.use_zone("Eastern Time (US & Canada)") do
        freeze_time DateTime.parse("2023-10-31 06:00:00 -0400")
        described_class.new.execute(current_user_id: east_coast_user.id, invites: invites)
        invite = Invite.first
        expect(invite.expires_at.hour).to equal(6)
      end
    end

    it "does not create invited groups for automatic groups" do
      group2.update!(automatic: true)

      described_class.new.execute(current_user_id: admin.id, invites: invites)

      invite = Invite.last
      expect(invite.email).to eq(email)
      expect(invite.invited_groups.pluck(:group_id)).to contain_exactly(group1.id)

      post = Post.last
      expect(post.raw).to include("1 warning")
    end

    it "does not create invited groups record if the user can not manage the group" do
      group1.add_owner(user)

      described_class.new.execute(current_user_id: user.id, invites: invites)

      invite = Invite.last
      expect(invite.email).to eq(email)
      expect(invite.invited_groups.pluck(:group_id)).to contain_exactly(group1.id)
    end

    it "adds existing users to valid groups" do
      existing_user = Fabricate(:user, email: "test@discourse.org")

      group2.update!(automatic: true)

      expect do
        described_class.new.execute(current_user_id: admin.id, invites: invites)
      end.to change { Invite.count }.by(2)

      expect(Invite.exists?(email: staged_user.email)).to eq(true)
      expect(Invite.exists?(email: "test2@discourse.org")).to eq(true)
      expect(existing_user.reload.groups).to eq([group1])
    end

    it "can create staged users and prepopulate user fields" do
      user_field = Fabricate(:user_field, name: "Location")
      user_field_color = Fabricate(:user_field, field_type: "dropdown", name: "Color")
      user_field_color.user_field_options.create!(value: "Red")
      user_field_color.user_field_options.create!(value: "Green")
      user_field_color.user_field_options.create!(value: "Blue")

      described_class.new.execute(
        current_user_id: admin.id,
        invites: [
          { email: "test@discourse.org" }, # new user without user fields
          { email: user.email, location: "value 1", color: "blue" }, # existing user with user fields
          { email: staged_user.email, location: "value 2", color: "redd" }, # existing staged user with user fields
          { email: "test2@discourse.org", location: "value 3" }, # new staged user with user fields
        ],
      )

      expect(Invite.count).to eq(3)
      expect(User.where(staged: true).find_by_email("test@discourse.org")).to eq(nil)
      expect(user.user_fields[user_field.id.to_s]).to eq("value 1")
      expect(user.user_fields[user_field_color.id.to_s]).to eq("Blue")
      expect(staged_user.user_fields[user_field.id.to_s]).to eq("value 2")
      expect(staged_user.user_fields[user_field_color.id.to_s]).to eq(nil)
      new_staged_user = User.where(staged: true).find_by_email("test2@discourse.org")
      expect(new_staged_user.user_fields[user_field.id.to_s]).to eq("value 3")
    end

    it "includes any skipped and failed emails in the private message" do
      described_class.new.execute(
        current_user_id: admin.id,
        invites: [{ email: "bad_email" }, { email: user.email }, { email: "test@discourse.org" }],
      )

      post = Post.last
      result = parse_skipped_and_failed_emails(post.raw)
      expect(result[:skipped_invites]).to eq(user.email)
      expect(result[:failed_invites]).to eq("bad_email")
    end

    context "when there are more than 200 invites" do
      let(:bulk_invites) { [] }

      before { 202.times { |i| bulk_invites << { email: "test_#{i}@discourse.org" } } }

      it "rate limits email sending" do
        described_class.new.execute(current_user_id: admin.id, invites: bulk_invites)

        invite = Invite.last
        expect(invite.email).to eq("test_201@discourse.org")
        expect(invite.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
        expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(1)
      end
    end

    it "does not send an invite email when skip_email_bulk_invites is true" do
      SiteSetting.skip_email_bulk_invites = true

      described_class.new.execute(current_user_id: admin.id, invites: invites)

      invite = Invite.last
      expect(invite.emailed_status).to eq(Invite.emailed_status_types[:not_required])
    end

    context "with allow_any_email" do
      it "creates an unbound invite" do
        described_class.new.execute(
          current_user_id: admin.id,
          invites: [{ email: "student@college.edu", allow_any_email: "true" }],
        )

        invite = Invite.last
        expect(invite.email).to eq(nil)
        expect(invite.is_invite_link?).to eq(true)
        expect(invite.description).to eq("student@college.edu")
      end

      it "marks the invite as emailed so it's eligible for Resend All Invites" do
        described_class.new.execute(
          current_user_id: admin.id,
          invites: [{ email: "student@college.edu", allow_any_email: "true" }],
        )

        expect(Invite.last.emailed_status).not_to eq(Invite.emailed_status_types[:not_required])
      end

      it "keeps the invite bound when absent or false" do
        described_class.new.execute(
          current_user_id: admin.id,
          invites: [
            { email: "student1@college.edu" },
            { email: "student2@college.edu", allow_any_email: "false" },
          ],
        )

        Invite
          .where(email: %w[student1@college.edu student2@college.edu])
          .find_each do |invite|
            expect(invite.email).to be_present
            expect(invite.description).to eq(nil)
          end
      end

      it "keeps the invite bound for any non-explicit-true spelling (fails closed)" do
        described_class.new.execute(
          current_user_id: admin.id,
          invites: [
            { email: "student3@college.edu", allow_any_email: "no" },
            { email: "student4@college.edu", allow_any_email: "maybe" },
            { email: "student5@college.edu", allow_any_email: "disabled" },
          ],
        )

        Invite
          .where(email: %w[student3@college.edu student4@college.edu student5@college.edu])
          .find_each { |invite| expect(invite.email).to be_present }
      end

      it "delivers the invite to the CSV address" do
        Jobs.run_immediately!
        mailer = Mail::Message.new(to: "student@college.edu")
        Email::Sender.any_instance.expects(:send)
        InviteMailer
          .expects(:send_invite)
          .with(anything, has_entries(to: "student@college.edu"))
          .returns(mailer)

        described_class.new.execute(
          current_user_id: admin.id,
          invites: [{ email: "student@college.edu", allow_any_email: "true" }],
        )
      end

      it "does not enqueue delivery when skip_email_bulk_invites is true" do
        SiteSetting.skip_email_bulk_invites = true

        described_class.new.execute(
          current_user_id: admin.id,
          invites: [{ email: "student@college.edu", allow_any_email: "true" }],
        )

        expect(Jobs::InviteEmail.jobs).to be_empty
      end

      it "does not misinterpret allow_any_email as a user field" do
        described_class.new.execute(
          current_user_id: admin.id,
          invites: [{ email: "student@college.edu", allow_any_email: "true" }],
        )

        post = Post.last
        expect(post.raw).to include("0 warning")
      end

      it "still applies groups and topic to an unbound invite" do
        described_class.new.execute(
          current_user_id: admin.id,
          invites: [
            {
              email: "student@college.edu",
              allow_any_email: "true",
              groups: "GROUP1;group2",
              topic_id: topic.id,
            },
          ],
        )

        invite = Invite.last
        expect(invite.invited_groups.pluck(:group_id)).to contain_exactly(group1.id, group2.id)
        expect(invite.topic_invites.pluck(:topic_id)).to contain_exactly(topic.id)
      end

      it "does not create an orphaned staged user when prefilling fields for an unbound invite" do
        user_field = Fabricate(:user_field, name: "Location")

        described_class.new.execute(
          current_user_id: admin.id,
          invites: [{ email: "student@college.edu", allow_any_email: "true", location: "value 1" }],
        )

        expect(User.where(staged: true).find_by_email("student@college.edu")).to eq(nil)
        expect(Invite.last.email).to eq(nil)

        post = Post.last
        expect(post.raw).to include("1 warning")
      end

      it "rate limits repeated allow_any_email rows to the same address" do
        RateLimiter.enable
        # Staff (e.g. admin) are exempt from this limiter by default, same as the
        # bound-email reinvites-per-day check it mirrors -- use a non-staff inviter
        # so the limit is actually exercised.

        4.times do
          described_class.new.execute(
            current_user_id: user.id,
            invites: [{ email: "student@college.edu", allow_any_email: "true" }],
          )
        end

        expect(Invite.where(description: "student@college.edu", email: nil).count).to eq(3)

        post = Post.last
        expect(post.raw).to include("1 error(s)")
      end

      it "shares the rate limit budget across differently-cased rows for the same address" do
        RateLimiter.enable

        described_class.new.execute(
          current_user_id: user.id,
          invites: [
            { email: "student@college.edu", allow_any_email: "true" },
            { email: "Student@College.edu", allow_any_email: "true" },
            { email: "STUDENT@COLLEGE.EDU", allow_any_email: "true" },
            { email: "sTuDeNt@college.edu", allow_any_email: "true" },
          ],
        )

        expect(Invite.where(email: nil).count).to eq(3)

        post = Post.last
        expect(post.raw).to include("1 error(s)")
      end

      it "does not immediately enqueue delivery for a bulk_pending batch" do
        bulk_invites =
          (Invite::BULK_INVITE_EMAIL_LIMIT + 1).times.map do |i|
            { email: "student#{i}@college.edu", allow_any_email: "true" }
          end

        described_class.new.execute(current_user_id: admin.id, invites: bulk_invites)

        invite = Invite.last
        expect(invite.emailed_status).to eq(Invite.emailed_status_types[:bulk_pending])
        expect(Jobs::InviteEmail.jobs).to be_empty
        expect(Jobs::ProcessBulkInviteEmails.jobs.size).to eq(1)
      end
    end
  end
end
