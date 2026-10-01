# frozen_string_literal: true

require Rails.root.join(
          "db/migrate/20261001153631_backfill_invites_email_domain_from_description.rb",
        )

RSpec.describe BackfillInvitesEmailDomainFromDescription do
  fab!(:user)

  before do
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  after { ActiveRecord::Migration.verbose = @original_verbose }

  # Invite's own before_save already derives email_domain correctly (that's
  # the accompanying model fix) -- force it back to nil here to simulate a
  # legacy row created before that fix existed, which is exactly what this
  # migration needs to repair on real sites.
  def simulate_legacy_row(email:, description:, max_redemptions_allowed: 5)
    invite =
      Fabricate(
        :invite,
        invited_by: user,
        email: email,
        description: description,
        max_redemptions_allowed: max_redemptions_allowed,
      )
    invite.update_columns(email_domain: nil)
    invite
  end

  it "backfills email_domain from an email-shaped description" do
    invite = simulate_legacy_row(email: nil, description: "student@nit.ac.in")

    described_class.new.up

    expect(invite.reload.email_domain).to eq("nit.ac.in")
  end

  it "does not touch a row whose description isn't email-shaped" do
    invite = simulate_legacy_row(email: nil, description: "met at the career fair")

    described_class.new.up

    expect(invite.reload.email_domain).to eq(nil)
  end

  it "does not touch a row that already has an email (email_domain already backfilled elsewhere)" do
    invite = Fabricate(:invite, invited_by: user, email: "bound@example.com")
    invite.update_columns(email_domain: nil)

    described_class.new.up

    expect(invite.reload.email_domain).to eq(nil)
  end

  it "does not overwrite a row that already has an email_domain" do
    invite = simulate_legacy_row(email: nil, description: "student@nit.ac.in")
    invite.update_columns(email_domain: "already-set.example.com")

    described_class.new.up

    expect(invite.reload.email_domain).to eq("already-set.example.com")
  end
end
