# frozen_string_literal: true

RSpec.describe BulkInviteUrlExtraction::DraftCreator do
  fab!(:admin)
  fab!(:group)
  fab!(:topic)

  def csv(rows)
    header = "email,name,groups,topic_id,locale,keywords"
    ([header] + rows).join("\n")
  end

  describe ".create_drafts" do
    it "creates a draft invite per valid row, never enqueuing a send" do
      result =
        described_class.create_drafts(
          current_user: admin,
          csv_text: csv(["priya@iitb.ac.in,Priya,,,en,physics students"]),
          allow_any_email: false,
          schedule_send: true,
          skip_personalization: false,
        )

      expect(result.created_count).to eq(1)
      expect(result.errors).to eq([])

      invite = Invite.find_by(email: "priya@iitb.ac.in")
      expect(invite).to be_present
      expect(invite.emailed_status).to eq(Invite.emailed_status_types[:draft])
      expect(invite.recipient_name).to eq("Priya")
      expect(invite.recipient_keywords).to eq("physics students")
      expect(invite.schedule_send).to eq(true)
      expect(invite.skip_personalization).to eq(false)
      expect(Jobs::InviteEmail.jobs.size).to eq(0)
      expect(Jobs::BulkInvite.jobs.size).to eq(0)
    end

    it "drops a row with a blank email without recording an error" do
      result =
        described_class.create_drafts(
          current_user: admin,
          csv_text: csv([",,,,,"]),
          allow_any_email: false,
          schedule_send: true,
          skip_personalization: false,
        )

      expect(result.created_count).to eq(0)
      expect(result.errors).to eq([])
    end

    it "records an error for an invalid email instead of creating an invite" do
      result =
        described_class.create_drafts(
          current_user: admin,
          csv_text: csv(["not-an-email,,,,,"]),
          allow_any_email: false,
          schedule_send: true,
          skip_personalization: false,
        )

      expect(result.created_count).to eq(0)
      expect(result.errors).to eq(["Invalid email 'not-an-email'"])
    end

    it "resolves a semicolon-separated groups column, recording an error for an unknown group" do
      result =
        described_class.create_drafts(
          current_user: admin,
          csv_text: csv(["a@example.com,,#{group.name};unknown-group,,,"]),
          allow_any_email: false,
          schedule_send: true,
          skip_personalization: false,
        )

      invite = Invite.find_by(email: "a@example.com")
      expect(invite.groups).to eq([group])
      expect(result.errors.join).to include("Invalid group 'unknown-group'")
    end

    it "resolves a topic_id column, recording an error for an invalid topic" do
      result =
        described_class.create_drafts(
          current_user: admin,
          csv_text: csv(["a@example.com,,,#{topic.id},,", "b@example.com,,,-1,,"]),
          allow_any_email: false,
          schedule_send: true,
          skip_personalization: false,
        )

      bound_invite = Invite.find_by(email: "a@example.com")
      expect(bound_invite.topics).to eq([topic])
      expect(result.errors.join).to include("Invalid topic ID '-1'")
    end

    it "leaves the invite unbound (email nil, description set) when allow_any_email is true" do
      described_class.create_drafts(
        current_user: admin,
        csv_text: csv(["a@example.com,,,,,"]),
        allow_any_email: true,
        schedule_send: true,
        skip_personalization: false,
      )

      invite = Invite.find_by(description: "a@example.com")
      expect(invite.email).to be_nil
      expect(invite.allow_any_email).to eq(true)
    end

    it "does not let a non-staff user without bulk invite permission create drafts for a restricted group" do
      user = Fabricate(:user)
      restricted_group = Fabricate(:group)

      result =
        described_class.create_drafts(
          current_user: user,
          csv_text: csv(["a@example.com,,#{restricted_group.name},,,"]),
          allow_any_email: false,
          schedule_send: true,
          skip_personalization: false,
        )

      invite = Invite.find_by(email: "a@example.com")
      expect(invite&.groups).to eq([])
      expect(result.errors.join).to include("Invalid group '#{restricted_group.name}'")
    end
  end
end
