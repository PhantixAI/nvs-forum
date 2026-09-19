# frozen_string_literal: true

class User::Action::CreateFromVerifiedEmail < Service::ActionBase
  option :email
  option :ip_address, optional: true
  option :user_fields, optional: true
  option :name, optional: true
  option :password, optional: true
  option :username, optional: true

  def call
    raise Discourse::SiteArchived if SiteSetting.site_archived

    user = User.where(staged: true).with_email(email).first
    user&.unstage!
    user ||= User.new

    # The person's own name comes first so the username they start with is
    # one they have no reason to change -- a changed username leaves stored
    # links to it (e.g. in notifications) pointing nowhere. A random name
    # beats the generic "userN" fallback after that: there is no signup form
    # where the user could pick one before the account exists. Sites that
    # turn random names off fall through to that generic name.
    suggested_username =
      username_from_name(name.presence || user.name) ||
        UserNameSuggester.suggest(email, allow_generic_fallback: false) ||
        RandomUsernameGenerator.generate || UserNameSuggester.suggest(email)

    user.attributes = {
      email: email,
      username: username.presence || suggested_username,
      # The generated username is a placeholder, so it must never become the
      # full name. A staged account's existing name is real and survives.
      name: name.presence || user.name,
      active: false,
      locale: I18n.locale,
      ip_address: ip_address,
      registration_ip_address: ip_address,
    }

    assign_user_fields(user)
    user.password = password if password.present?

    user.enforce_username_restrictions = username.present?

    if SiteSetting.must_approve_users? && EmailValidator.can_auto_approve_user?(email)
      ReviewableUser.set_approved_fields!(user, Discourse.system_user)
    end

    user.tap(&:save)
  end

  private

  def username_from_name(full_name)
    return if !SiteSetting.use_name_for_username_suggestions || full_name.blank?

    UserNameSuggester.suggest(full_name, allow_generic_fallback: false)
  end

  def assign_user_fields(user)
    return if user_fields.blank?

    fields = user.custom_fields
    UserField
      .where(show_on_signup: true)
      .pluck(:id)
      .each do |field_id|
        value = user_fields[field_id.to_s]
        value = nil if value == "false"
        fields["#{User::USER_FIELD_PREFIX}#{field_id}"] = value[
          0...UserField.max_length
        ] if value.present?
      end
    user.custom_fields = fields
  end
end
