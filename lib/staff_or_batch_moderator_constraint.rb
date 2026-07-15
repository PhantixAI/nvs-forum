# frozen_string_literal: true

# Like StaffConstraint, but also admits a logged-in Batch Moderator (owner of
# a batch-moderation cohort group) -- used only by the admin users list
# route, so a Batch Moderator can reach that one page without being staff.
# Every other /admin route stays gated by the plain StaffConstraint.
class StaffOrBatchModeratorConstraint
  def matches?(request)
    # Delegates to StaffConstraint first so a plugin's `custom_staff_check`
    # override (its own documented extensibility point) still applies to
    # staff on this route, exactly as it does on every other /admin route --
    # only the non-staff Batch Moderator fallback bypasses it, since that
    # check was never about batch moderators to begin with.
    return true if StaffConstraint.new.matches?(request)

    current_user = CurrentUser.lookup_from_env(request.env)
    return false if current_user.nil?
    BatchModeration::GroupSync.owned_batch_groups(current_user).exists?
  rescue Discourse::InvalidAccess, Discourse::ReadOnly
    false
  end
end
