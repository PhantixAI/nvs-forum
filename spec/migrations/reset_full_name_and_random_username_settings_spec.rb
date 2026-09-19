# frozen_string_literal: true

require Rails.root.join("db/migrate/20260919072524_reset_full_name_and_random_username_settings.rb")

RSpec.describe ResetFullNameAndRandomUsernameSettings do
  before do
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  after { ActiveRecord::Migration.verbose = @original_verbose }

  def override(name, value, type)
    DB.exec(
      "INSERT INTO site_settings (name, data_type, value, created_at, updated_at)
       VALUES (:name, :type, :value, now(), now())",
      name:,
      type:,
      value:,
    )
  end

  it "removes the overrides so the new defaults apply, leaving other settings alone" do
    override("full_name_requirement", "hidden_at_signup", SiteSetting.types[:enum])
    override("enable_random_usernames", "f", SiteSetting.types[:bool])
    override("enable_names", "f", SiteSetting.types[:bool])
    override("random_username_nouns", "fox|owl", SiteSetting.types[:list])

    described_class.new.up

    remaining = DB.query_single("SELECT name FROM site_settings")
    expect(remaining).to include("random_username_nouns")
    expect(remaining).not_to include(
      "full_name_requirement",
      "enable_random_usernames",
      "enable_names",
    )
  end
end
