# frozen_string_literal: true

RSpec.describe Jobs::InviteEmail do
  describe ".execute" do
    it "raises an error when the invite_id is missing" do
      expect { Jobs::InviteEmail.new.execute({}) }.to raise_error(Discourse::InvalidParameters)
    end

    context "with an invite id" do
      let(:mailer) { Mail::Message.new(to: "eviltrout@test.domain") }
      fab!(:invite)

      it "delegates to the test mailer" do
        Email::Sender.any_instance.expects(:send)
        InviteMailer.expects(:send_invite).with(invite, anything).returns(mailer)
        Jobs::InviteEmail.new.execute(invite_id: invite.id)
      end

      it "aborts without error when the invite doesn't exist anymore" do
        invite.destroy
        InviteMailer.expects(:send_invite).never
        Jobs::InviteEmail.new.execute(invite_id: invite.id)
      end

      it "updates invite emailed_status" do
        invite.emailed_status = Invite.emailed_status_types[:pending]
        invite.save!
        Jobs::InviteEmail.new.execute(invite_id: invite.id)

        invite.reload
        expect(invite.emailed_status).to eq(Invite.emailed_status_types[:sent])
      end

      it "does not send email when allow_email_invites is disabled" do
        SiteSetting.allow_email_invites = false
        InviteMailer.expects(:send_invite).never
        Jobs::InviteEmail.new.execute(invite_id: invite.id)
      end

      it "passes to_override through to the mailer" do
        Email::Sender.any_instance.expects(:send)
        InviteMailer
          .expects(:send_invite)
          .with(invite, invite_to_topic: nil, to: "override@example.com")
          .returns(mailer)
        Jobs::InviteEmail.new.execute(invite_id: invite.id, to_override: "override@example.com")
      end

      it "omits to_override when not given" do
        Email::Sender.any_instance.expects(:send)
        InviteMailer
          .expects(:send_invite)
          .with(invite, invite_to_topic: nil, to: nil)
          .returns(mailer)
        Jobs::InviteEmail.new.execute(invite_id: invite.id)
      end

      it "falls back to invite.description when the invite is unbound and no override is given" do
        unbound_invite =
          Invite.generate(
            invite.invited_by,
            email: nil,
            description: "student@college.edu",
            max_redemptions_allowed: 10,
          )

        Email::Sender.any_instance.expects(:send)
        InviteMailer
          .expects(:send_invite)
          .with(unbound_invite, invite_to_topic: nil, to: "student@college.edu")
          .returns(mailer)
        Jobs::InviteEmail.new.execute(invite_id: unbound_invite.id)
      end

      it "skips sending when the invite is unbound and description is blank" do
        unbound_invite = Invite.generate(invite.invited_by, email: nil, max_redemptions_allowed: 10)

        InviteMailer.expects(:send_invite).never
        Jobs::InviteEmail.new.execute(invite_id: unbound_invite.id)
      end

      it "skips sending when the invite is unbound and description isn't a valid email" do
        unbound_invite =
          Invite.generate(
            invite.invited_by,
            email: nil,
            description: "not an email",
            max_redemptions_allowed: 10,
          )

        InviteMailer.expects(:send_invite).never
        Jobs::InviteEmail.new.execute(invite_id: unbound_invite.id)
      end

      it "leaves emailed_status unchanged (not :sent) when the skip guard trips" do
        unbound_invite =
          Invite.generate(
            invite.invited_by,
            email: nil,
            description: "not an email",
            max_redemptions_allowed: 10,
          )
        unbound_invite.update_column(:emailed_status, Invite.emailed_status_types[:sending])

        Jobs::InviteEmail.new.execute(invite_id: unbound_invite.id)

        expect(unbound_invite.reload.emailed_status).to eq(Invite.emailed_status_types[:sending])
      end

      it "recovers on a later run once the description is fixed" do
        unbound_invite =
          Invite.generate(
            invite.invited_by,
            email: nil,
            description: "not an email",
            max_redemptions_allowed: 10,
          )
        unbound_invite.update_column(:emailed_status, Invite.emailed_status_types[:sending])

        InviteMailer.expects(:send_invite).never
        Jobs::InviteEmail.new.execute(invite_id: unbound_invite.id)
        expect(unbound_invite.reload.emailed_status).to eq(Invite.emailed_status_types[:sending])

        unbound_invite.update_column(:description, "student@college.edu")

        Email::Sender.any_instance.expects(:send)
        InviteMailer
          .expects(:send_invite)
          .with(unbound_invite, invite_to_topic: nil, to: "student@college.edu")
          .returns(mailer)
        Jobs::InviteEmail.new.execute(invite_id: unbound_invite.id)

        expect(unbound_invite.reload.emailed_status).to eq(Invite.emailed_status_types[:sent])
      end
    end
  end
end
