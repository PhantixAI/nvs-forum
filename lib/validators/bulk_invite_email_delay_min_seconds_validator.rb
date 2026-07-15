# frozen_string_literal: true

class BulkInviteEmailDelayMinSecondsValidator
  def initialize(opts = {})
    @opts = opts
  end

  def valid_value?(value)
    value = value.to_i

    if value < 1
      @range_violation = true
      return false
    end

    value <= SiteSetting.bulk_invite_email_delay_max_seconds
  end

  def error_message
    if @range_violation
      I18n.t("site_settings.errors.invalid_integer_min", min: 1)
    else
      I18n.t("site_settings.errors.bulk_invite_email_delay_min")
    end
  end
end
