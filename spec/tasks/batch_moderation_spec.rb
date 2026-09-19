# frozen_string_literal: true

# The tasks loop over every configured site, and in specs that list comes from
# the tracked multisite config -- i.e. production. Scope them to the test DB.
RSpec.shared_context "with only the current site" do
  before do
    RailsMultisite::ConnectionManagement.stubs(:each_connection).yields(
      RailsMultisite::ConnectionManagement.current_db,
    )
  end
end

describe "batch_moderation:resync_cohorts" do
  include_context "with only the current site"

  fab!(:college_field) { Fabricate(:user_field, name: "College", requirement: "optional") }
  fab!(:branch_field) { Fabricate(:user_field, name: "Branch", requirement: "optional") }
  fab!(:batch_field) { Fabricate(:user_field, name: "Batch", requirement: "optional") }
  fab!(:user)

  before do
    Rake::Task.clear
    silence_warnings { Discourse::Application.load_tasks }
  end

  def set_fields(user, college:, branch:, batch:)
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{college_field.id}"] = college
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{branch_field.id}"] = branch
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{batch_field.id}"] = batch
    user.save_custom_fields(true, run_validations: false)
  end

  it "does nothing when the site setting is disabled" do
    SiteSetting.enable_batch_moderation = false
    set_fields(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")

    expect { invoke_rake_task("batch_moderation:resync_cohorts") }.not_to change { Group.count }
  end

  it "re-syncs every user into their correctly-keyed cohort group" do
    SiteSetting.enable_batch_moderation = true
    set_fields(user, college: "MNIT Jaipur", branch: "CSE", batch: "2024")

    invoke_rake_task("batch_moderation:resync_cohorts")

    group = Group.last
    expect(BatchModeration::GroupSync.batch_group?(group)).to eq(true)
    expect(group.users).to include(user)
  end

  it "leaves non-batch groups untouched" do
    SiteSetting.enable_batch_moderation = true
    regular_group = Fabricate(:group)

    invoke_rake_task("batch_moderation:resync_cohorts")

    expect(Group.exists?(regular_group.id)).to eq(true)
  end
end

describe "batch_moderation:backfill_member_type" do
  include_context "with only the current site"

  fab!(:branch_field) { Fabricate(:user_field, name: "Branch", requirement: "optional") }
  fab!(:batch_field) { Fabricate(:user_field, name: "Batch", requirement: "optional") }

  before do
    Rake::Task.clear
    silence_warnings { Discourse::Application.load_tasks }
    SiteSetting.batch_moderation_secondary_field_names = "Branch"
    SiteSetting.batch_moderation_staff_type_values = "Dean/Professor/Staff"
    # Every example here wants real writes by default; the one dry-run example
    # below explicitly deletes this to exercise the (unset) default instead.
    ENV["DRY_RUN"] = "0"
  end

  after { ENV.delete("DRY_RUN") }

  def set_fields(user, branch:, batch:)
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{branch_field.id}"] = branch
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{batch_field.id}"] = batch
    user.save_custom_fields(true, run_validations: false)
  end

  def type_value_for(user)
    field = UserField.find_by(name: "I am")
    field && user.reload.custom_fields["#{User::USER_FIELD_PREFIX}#{field.id}"]
  end

  it "creates the member-type field and its options when missing" do
    expect { invoke_rake_task("batch_moderation:backfill_member_type") }.to change {
      UserField.exists?(name: "I am")
    }.from(false).to(true)

    field = UserField.find_by(name: "I am")
    expect(field.field_type).to eq("dropdown")
    expect(field.requirement).to eq("for_all_users")
    expect(field.user_field_options.pluck(:value)).to contain_exactly(
      "Alumni/Student",
      "Dean/Professor/Staff",
    )
  end

  it "reuses an already-existing field and its options without duplicating them" do
    existing =
      Fabricate(:user_field, name: "I am", field_type: "dropdown", requirement: "for_all_users")
    existing.user_field_options.create!(value: "Alumni/Student")
    existing.user_field_options.create!(value: "Dean/Professor/Staff")

    expect { invoke_rake_task("batch_moderation:backfill_member_type") }.not_to change {
      UserField.count
    }
    expect(existing.reload.user_field_options.count).to eq(2)
  end

  it "classifies a user with both Batch and Branch set as Student" do
    student = Fabricate(:user)
    set_fields(student, branch: "CSE", batch: "2024")

    invoke_rake_task("batch_moderation:backfill_member_type")

    expect(type_value_for(student)).to eq("Alumni/Student")
  end

  it "classifies a user missing Branch (or Batch) as Staff" do
    staff_member = Fabricate(:user)
    set_fields(staff_member, branch: nil, batch: "2024")

    invoke_rake_task("batch_moderation:backfill_member_type")

    expect(type_value_for(staff_member)).to eq("Dean/Professor/Staff")
  end

  it "skips a user who already has a member-type value set" do
    field = Fabricate(:user_field, name: "I am", field_type: "dropdown")
    user = Fabricate(:user)
    set_fields(user, branch: "CSE", batch: "2024")
    user.custom_fields["#{User::USER_FIELD_PREFIX}#{field.id}"] = "Dean/Professor/Staff"
    user.save_custom_fields(true, run_validations: false)

    invoke_rake_task("batch_moderation:backfill_member_type")

    expect(type_value_for(user)).to eq("Dean/Professor/Staff")
  end

  it "makes no changes in dry-run mode (the default)" do
    ENV.delete("DRY_RUN")
    user = Fabricate(:user)
    set_fields(user, branch: "CSE", batch: "2024")

    expect { invoke_rake_task("batch_moderation:backfill_member_type") }.not_to change {
      UserField.count
    }
    expect(type_value_for(user)).to be_nil
  end
end

describe "batch_moderation:revoke_site_moderators" do
  include_context "with only the current site"

  before do
    Rake::Task.clear
    silence_warnings { Discourse::Application.load_tasks }
  end

  it "revokes moderation from a non-admin moderator" do
    moderator = Fabricate(:user, moderator: true)
    ENV["DRY_RUN"] = "0"

    invoke_rake_task("batch_moderation:revoke_site_moderators")

    expect(moderator.reload.moderator).to eq(false)
  ensure
    ENV.delete("DRY_RUN")
  end

  it "leaves an admin's moderator status untouched" do
    admin_mod = Fabricate(:user, admin: true, moderator: true)
    ENV["DRY_RUN"] = "0"

    invoke_rake_task("batch_moderation:revoke_site_moderators")

    expect(admin_mod.reload.moderator).to eq(true)
  ensure
    ENV.delete("DRY_RUN")
  end

  it "makes no changes in dry-run mode (the default)" do
    moderator = Fabricate(:user, moderator: true)

    invoke_rake_task("batch_moderation:revoke_site_moderators")

    expect(moderator.reload.moderator).to eq(true)
  end
end
