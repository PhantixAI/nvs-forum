# frozen_string_literal: true

module InviteGuardian
  def can_see_invite_details?(user)
    is_staff? || is_me?(user)
  end

  def can_see_invite_emails?(user)
    is_staff? || is_me?(user)
  end

  def can_create_admin_invite?
    is_admin? && @user.upcoming_change_enabled?(:enable_invite_modal_with_roles)
  end

  def can_invite_to_forum?(groups = nil)
    return false if !authenticated?
    return false if !@user.in_any_groups?(SiteSetting.invite_allowed_groups_map)
    return false if !SiteSetting.max_invites_per_day.to_i.positive? && !is_staff?

    groups.blank? || groups.all? { |g| can_edit_group?(g) }
  end

  def can_invite_to?(object, groups = nil)
    return false if !authenticated?
    return false if !object.is_a?(Topic) || !can_see?(object)
    return false if groups.present?

    if object.is_a?(Topic)
      if object.private_message?
        return true if is_admin?

        return false if !@user.in_any_groups?(SiteSetting.personal_message_enabled_groups_map)
        return false if object.reached_recipients_limit? && !is_staff?
      end

      if (category = object.category) && category.read_restricted
        return category.groups&.where(automatic: false)&.any? { |g| can_edit_group?(g) }
      end
    end

    true
  end

  def can_invite_via_email?(object)
    return false if !can_invite_to_forum?
    return false if !can_invite_to?(object)

    (SiteSetting.enable_local_logins || SiteSetting.enable_discourse_connect) &&
      (!SiteSetting.must_approve_users? || is_staff?)
  end

  def can_bulk_invite_to_forum?
    is_staff?
  end

  # Reuses can_bulk_invite_to_forum?'s trust boundary (admin, moderator, or Batch Moderator,
  # once BatchModeration::GuardianExtension is prepended) for a different purpose: whether
  # this user's invites skip the email-domain allowlist entirely. A Batch Moderator's bulk
  # invite is always admin-reviewed before it's ever processed (see ReviewableBulkInvite), but
  # invited_by stays the original Batch Moderator even after approval -- so checking is_staff?
  # alone here would miss them.
  def can_skip_email_domain_validation?
    can_bulk_invite_to_forum?
  end

  # Same trust boundary as #can_destroy_all_invites? below -- staff may bulk
  # resend/cancel-schedule/cancel-drafting for themselves, but acting on another
  # user's invited page this way requires admin. These are non-destructive, but
  # still affect another user's data (sends real email, reschedules AI
  # personalization) on their behalf, so get the same self-or-admin gate as
  # deletion rather than the broader is_staff?-for-anyone this used to be --
  # that broader check predates the invited-page viewing the viewed user's own
  # invites now being possible per the fix that introduced this stricter check.
  def can_resend_all_invites?(user)
    is_staff? && (is_admin? || is_me?(user))
  end

  def can_destroy_all_invites?(user)
    is_staff? && (is_admin? || is_me?(user))
  end

  def can_destroy_invite?(invite)
    invite && (is_admin? || is_me?(invite.invited_by))
  end
end
