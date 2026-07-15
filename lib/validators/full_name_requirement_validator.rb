# frozen_string_literal: true

# Batch moderation and notification links rely on every account having a
# real name at signup (usernames are derived from it), so this setting is
# pinned rather than left for an admin to relax.
class FullNameRequirementValidator
  def initialize(opts = {})
    @opts = opts
  end

  def valid_value?(value)
    value == "required_at_signup"
  end

  def error_message
    I18n.t("site_settings.errors.full_name_requirement_locked")
  end
end
