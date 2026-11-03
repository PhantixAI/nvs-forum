# frozen_string_literal: true

require Rails.root.join("db/migrate/20261102194941_merge_duplicate_invite_rows.rb")

RSpec.describe MergeDuplicateInviteRows do
  before do
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  after { ActiveRecord::Migration.verbose = @original_verbose }

  fab!(:inviter, :user)

  it "keeps the most-redeemed duplicate shareable link and trashes the zero-redemption rest, case-insensitively" do
    keep =
      Fabricate(
        :invite,
        invited_by: inviter,
        email: nil,
        description: "dup@example.com",
        allow_any_email: true,
        redemption_count: 1,
        max_redemptions_allowed: 5,
      )
    extra1 =
      Fabricate(
        :invite,
        invited_by: inviter,
        email: nil,
        description: "dup@example.com",
        allow_any_email: true,
        redemption_count: 0,
      )
    extra2 =
      Fabricate(
        :invite,
        invited_by: inviter,
        email: nil,
        description: "DUP@example.com",
        allow_any_email: true,
        redemption_count: 0,
      )

    described_class.new.up

    expect(keep.reload.deleted_at).to be_nil
    expect(extra1.reload.deleted_at).not_to be_nil
    expect(extra2.reload.deleted_at).not_to be_nil
  end

  it "keeps the most recently created duplicate bound invite" do
    older =
      Fabricate(:invite, invited_by: inviter, email: "dup@example.com", created_at: 2.days.ago)
    newer = Fabricate(:invite, invited_by: inviter, email: "dup@example.com", created_at: 1.day.ago)

    described_class.new.up

    expect(older.reload.deleted_at).not_to be_nil
    expect(newer.reload.deleted_at).to be_nil
  end

  it "never trashes a duplicate that already has its own redemptions" do
    a =
      Fabricate(
        :invite,
        invited_by: inviter,
        email: nil,
        description: "dup2@example.com",
        allow_any_email: true,
        redemption_count: 1,
        max_redemptions_allowed: 5,
        created_at: 2.days.ago,
      )
    b =
      Fabricate(
        :invite,
        invited_by: inviter,
        email: nil,
        description: "dup2@example.com",
        allow_any_email: true,
        redemption_count: 1,
        max_redemptions_allowed: 5,
        created_at: 1.day.ago,
      )

    described_class.new.up

    expect(a.reload.deleted_at).to be_nil
    expect(b.reload.deleted_at).to be_nil
  end

  it "leaves non-duplicate invites untouched" do
    solo = Fabricate(:invite, invited_by: inviter, email: "solo@example.com")

    described_class.new.up

    expect(solo.reload.deleted_at).to be_nil
  end

  it "does not treat invites from different inviters as duplicates of each other" do
    mine = Fabricate(:invite, invited_by: inviter, email: "shared@example.com")
    theirs = Fabricate(:invite, email: "shared@example.com")

    described_class.new.up

    expect(mine.reload.deleted_at).to be_nil
    expect(theirs.reload.deleted_at).to be_nil
  end
end
