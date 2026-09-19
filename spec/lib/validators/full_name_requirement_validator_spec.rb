# frozen_string_literal: true

RSpec.describe FullNameRequirementValidator do
  subject(:validator) { described_class.new }

  it "accepts only required_at_signup" do
    expect(validator.valid_value?("required_at_signup")).to eq(true)
    expect(validator.valid_value?("optional_at_signup")).to eq(false)
    expect(validator.valid_value?("hidden_at_signup")).to eq(false)
  end

  it "explains why other values are refused" do
    expect(validator.error_message).to eq(
      I18n.t("site_settings.errors.full_name_requirement_locked"),
    )
  end

  it "stops the setting being changed to another value" do
    expect { SiteSetting.full_name_requirement = "hidden_at_signup" }.to raise_error(
      Discourse::InvalidParameters,
    )
    expect(SiteSetting.defaults[:full_name_requirement]).to eq("required_at_signup")
  end
end
