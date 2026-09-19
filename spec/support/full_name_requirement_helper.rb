# frozen_string_literal: true

# full_name_requirement is pinned to required_at_signup (see
# FullNameRequirementValidator), which the upstream specs predate: many create
# users without a name. Examples therefore run in the mode those specs were
# written for, and any that need another mode say so with this helper rather
# than assigning the (now locked) setting.
module FullNameRequirementHelper
  def stub_full_name_requirement(value)
    SiteSetting.stubs(:full_name_requirement).returns(value)
  end
end

RSpec.configure do |config|
  config.include FullNameRequirementHelper
  config.before { stub_full_name_requirement("hidden_at_signup") }
end
