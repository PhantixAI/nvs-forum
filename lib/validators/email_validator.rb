# frozen_string_literal: true

class EmailValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    if value.blank?
      record.errors.add(attribute, I18n.t(:"user.email.blank"))
      invalid = true
    elsif !EmailAddressValidator.valid_value?(value)
      if Invite === record && attribute == :email
        record.errors.add(:base, I18n.t(:"invite.invalid_email", email: CGI.escapeHTML(value)))
      else
        record.errors.add(attribute, I18n.t(:"user.email.invalid"))
      end
      invalid = true
    end

    # `record.try(...)` lets a specific caller opt a record out of just the domain check
    # (e.g. InviteRedeemer.create_user_from_invite for an allow_any_email invite) without
    # touching the format/blocklist checks above and below. Other records validated by this
    # validator (e.g. Invite itself) don't define the accessor, so this is a no-op for them.
    if !record.try(:skip_email_domain_validation) && !EmailValidator.allowed?(value)
      record.errors.add(attribute, I18n.t(:"user.email.not_allowed"))
      invalid = true
    end

    if !invalid && ScreenedEmail.should_block?(value)
      record.errors.add(attribute, I18n.t(:"user.email.blocked"))
    end
  end

  def self.allowed?(email)
    if (setting = SiteSetting.allowed_email_domains).present?
      return email_in_restriction_setting?(setting, email) || is_developer?(email)
    elsif (setting = SiteSetting.blocked_email_domains).present?
      return !(email_in_restriction_setting?(setting, email) && !is_developer?(email))
    end

    true
  end

  def self.can_auto_approve_user?(email)
    if (setting = SiteSetting.auto_approve_email_domains).present?
      return !!(EmailValidator.allowed?(email) && email_in_restriction_setting?(setting, email))
    end

    false
  end

  def self.email_in_restriction_setting?(setting, value)
    domains = setting.gsub(".", '\.')
    regexp = Regexp.new("@(.+\\.)?(#{domains})$", true)
    value =~ regexp
  end

  def self.is_developer?(value)
    Rails.configuration.respond_to?(:developer_emails) &&
      Rails.configuration.developer_emails.include?(value)
  end
end
