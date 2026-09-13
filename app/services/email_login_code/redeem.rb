# frozen_string_literal: true

class EmailLoginCode::Redeem
  include Service::Base

  class << self
    # A brand-new account created by this call still has its machine-
    # generated placeholder username right through account creation AND
    # activation (both happen inside this one call) -- the real username
    # isn't picked until the signup flow's next screen. Deferring the
    # batch-moderator cohort sync that user_created/user_updated would
    # otherwise fire as a side effect of either step avoids baking that
    # placeholder into a cohort-change notification. See
    # BatchModeration::GroupSync::DEFER_SYNC_ON_SIGNUP_THREAD_KEY and
    # SessionController#finalize_login_code_signup, which runs the real,
    # deferred sync once the username is settled.
    def call(context = {}, &block)
      Thread.current[BatchModeration::GroupSync::DEFER_SYNC_ON_SIGNUP_THREAD_KEY] = true
      super
    ensure
      Thread.current[BatchModeration::GroupSync::DEFER_SYNC_ON_SIGNUP_THREAD_KEY] = nil
    end
  end

  params base_class: EmailLoginCode::Verify::Contract do
    attribute :user_fields
    attribute :name, :string

    before_validation do
      # Only hash-like input can carry field values; anything else (a stray
      # string/array) becomes an empty set so it fails as a missing field
      # rather than raising during normalization.
      self.user_fields =
        (
          if user_fields.is_a?(Hash) || user_fields.is_a?(ActionController::Parameters)
            user_fields.to_h.stringify_keys
          else
            {}
          end
        )
      self.name = name.to_s.strip.presence
    end

    validates :name, length: { maximum: 255 }
  end

  model :login_code
  policy :code_matches
  model :existing_user, :fetch_existing_user, optional: true
  policy :email_available_for_new_account
  policy :can_register_new_account
  policy :required_fields_provided
  policy :required_full_name_provided

  lock(:email) do
    transaction do
      step :consume_code
      model :user, :ensure_user
    end
  end

  only_if(:user_requires_activation?) do
    step :activate_user
    step :send_welcome_message
  end

  private

  def fetch_login_code(params:)
    EmailLoginCode.active.for_email(params.email).first
  end

  def code_matches(login_code:, params:)
    login_code.verify(params.code)
  end

  def fetch_existing_user(params:)
    User.real.where(staged: false).with_email(params.email).first
  end

  # Login matches on the exact address only, but a code's address can still
  # belong to an existing account once normalized (e.g. a Gmail alias). Such a
  # code can neither log in nor create an account, so it's treated as invalid
  # (via the controller's generic failure) rather than leaking a reason.
  def email_available_for_new_account(existing_user:, params:)
    return true if existing_user.present?

    User::Action::FindByEmail.call(email: params.email).blank?
  end

  def can_register_new_account(existing_user:, params:)
    return true if existing_user.present?

    # Mirrors EmailLoginCode::Request#deliverable? so account creation enforces
    # the same gates as the code request, even for a code issued before an
    # address was blocked or one created outside the request service.
    SiteSetting.allow_new_registrations && !SiteSetting.invite_only &&
      !SiteSetting.require_invite_code && EmailValidator.allowed?(params.email) &&
      !ScreenedEmail.should_block?(params.email)
  end

  def required_fields_provided(existing_user:, params:)
    return true if existing_user.present?

    values = params.user_fields.presence || {}
    # Only the fields shown at signup can be collected here (the UI and
    # CreateFromVerifiedEmail both use show_on_signup); requiring a hidden field
    # would make passwordless signup impossible to complete. Each field's
    # required-ness is also run through the same user_field_required_for_signup
    # modifier UsersController#create uses, so a field hidden by another
    # field's custom validation (e.g. Batch/Branch behind "I am") is exempted
    # here too rather than only on the client.
    UserField
      .where(show_on_signup: true)
      .all? do |field|
        value = values[field.id.to_s]
        next true if value.present? && value != "false"

        !DiscoursePluginRegistry.apply_modifier(
          :user_field_required_for_signup,
          field.required?,
          field,
          values,
        )
      end
  end

  def required_full_name_provided(existing_user:, params:)
    return true if existing_user.present?

    !Site.full_name_required_for_signup || params.name.present?
  end

  def consume_code(login_code:)
    # consume! is atomic; if it lost a race with a concurrent redemption the
    # code is already spent, so this redemption must not log anyone in.
    fail!("code already redeemed") unless login_code.consume!
  end

  def ensure_user(existing_user:, params:, ip_address:)
    existing_user ||
      User::Action::CreateFromVerifiedEmail.call(
        email: params.email,
        ip_address: ip_address,
        user_fields: params.user_fields,
        name: params.name,
      )
  end

  def user_requires_activation?(user:)
    !user.active?
  end

  def activate_user(user:)
    user.activate
  end

  def send_welcome_message(user:)
    # Don't welcome accounts that can't access the forum yet (e.g. awaiting
    # approval under must_approve_users), matching the normal signup path.
    return if !user.guardian.can_access_forum?

    user.enqueue_welcome_message("welcome_user")
  end
end
