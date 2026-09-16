# frozen_string_literal: true

class EmailLoginCode::Request
  include Service::Base

  params do
    attribute :email, :string
    attribute :signup, :boolean, default: false

    before_validation { self.email = email.to_s.strip.downcase }

    validates :email,
              presence: true,
              length: {
                maximum: 513,
              },
              format: {
                with: EmailAddressValidator.email_regex,
              }
  end

  only_if(:signup?) { policy :can_register_from_ip }
  model :user, optional: true
  only_if(:existing_account?) { step :trigger_before_email_login }

  policy :email_domain_allowed
  only_if(:deliverable?) do
    model :login_code, :generate_login_code
    step :send_login_code_email
  end

  private

  # Existing accounts always pass -- an allowlist change must not lock out
  # an existing user. For an email with no account yet, both a login and a
  # signup attempt are told the domain isn't allowed rather than left
  # silently waiting: this mirrors what /u/check_email already reveals to
  # any signup attempt regardless of whether that email has an account, so
  # it doesn't add a new email-enumeration channel -- the only thing this
  # newly distinguishes is "no account, disallowed domain" from "no
  # account, some other non-delivery reason," never "does this exact email
  # exist."
  #
  # Deliberately checks only allowed_email_domains, not the blocked_email_domains
  # branch of EmailValidator.allowed? -- a blocklist match must stay silent
  # like every other non-delivery reason (it's a blocklist of specific bad
  # actors/domains, not public site policy the way an allowlist is), so
  # `deliverable?` below still covers it via EmailValidator.allowed?.
  def email_domain_allowed(user:, params:)
    return true if user.present?

    setting = SiteSetting.allowed_email_domains
    return true if setting.blank?

    EmailValidator.email_in_restriction_setting?(setting, params.email) ||
      EmailValidator.is_developer?(params.email)
  end

  def signup?(params:)
    params.signup
  end

  def can_register_from_ip(ip_address:)
    !SpamHandler.should_prevent_registration_from_ip?(ip_address)
  end

  def fetch_user(params:)
    User.real.where(staged: false).with_email(params.email).first
  end

  def existing_account?(user:)
    user.present?
  end

  def trigger_before_email_login(user:)
    DiscourseEvent.trigger(:before_email_login, user)
  end

  def deliverable?(user:, params:)
    return true if user.present?
    return if !SiteSetting.allow_new_registrations
    return if SiteSetting.invite_only
    return if SiteSetting.require_invite_code
    # email_domain_allowed above already loudly rejects an allowed_email_domains
    # mismatch; this still needs to silently cover blocked_email_domains, which
    # EmailValidator.allowed? also checks.
    return if !EmailValidator.allowed?(params.email)
    return if ScreenedEmail.should_block?(params.email)
    # Login matches on the exact address, but a new account can't be created for
    # an email that already belongs to someone once normalized, so don't send a
    # code that could never be redeemed into an account.
    return if User::Action::FindByEmail.call(email: params.email)

    true
  end

  def generate_login_code(params:)
    EmailLoginCode.generate!(email: params.email)
  end

  def send_login_code_email(login_code:)
    Jobs.enqueue(:send_email_login_code, to_address: login_code.email, code: login_code.code)
  end
end
