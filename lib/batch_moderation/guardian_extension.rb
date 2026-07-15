# frozen_string_literal: true

module BatchModeration
  # Extends the core suspend/silence/group-edit permission checks with batch
  # moderation, without baking a site-specific feature directly into shared
  # Guardian code. Prepended onto `Guardian` in the initializer, mirroring how
  # plugins extend Guardian via `Guardian.prepend`.
  module GuardianExtension
    def can_suspend?(user)
      super || BatchModeration::Moderator.can_moderate?(self.user, user)
    end

    def can_deactivate?(user)
      can_suspend?(user)
    end

    def can_silence_user?(user)
      super || BatchModeration::Moderator.can_moderate?(self.user, user)
    end

    # A Batch Moderator's bulk invite is never processed directly -- see
    # InvitesController#upload_csv, which routes anyone who isn't staff
    # through ReviewableBulkInvite instead of enqueueing Jobs::BulkInvite.
    # That review step is the access control.
    def can_bulk_invite_to_forum?
      super || owns_batch_group?
    end

    # Batch groups are no longer editable via the stock group-page UI at all,
    # by anyone -- `Admin::UsersController#grant_batch_moderator`/
    # `#revoke_batch_moderator` are the sole path now. Leaving this open to
    # `can_admin_group?` (which can include moderators, via
    # `moderators_manage_groups`) would be a second, unnotified way to grant
    # ownership on these groups, bypassing both the admin-only restriction
    # and the notification hooks on the sanctioned path.
    def can_edit_group?(group)
      return false if BatchModeration::GroupSync.batch_group?(group)
      super
    end

    def can_grant_batch_moderator?(user)
      # Mirrors Moderator.shares_batch_group?'s own `target.staff?` exclusion --
      # Batch Moderator is a narrower stand-in for full Moderator on non-staff
      # users (see lib/tasks/batch_moderation.rake's revoke_site_moderators),
      # so an existing Admin/Moderator granted batch-group ownership on top
      # would be a meaningless, inconsistent staff+batch-owner state.
      !user.staff? && can_administer?(user) &&
        BatchModeration::GroupSync.batch_group_for(user).present? &&
        !BatchModeration::GroupSync.owned_batch_groups(user).exists?
    end

    def can_revoke_batch_moderator?(user)
      can_administer?(user) && BatchModeration::GroupSync.owned_batch_groups(user).exists?
    end

    private

    def owns_batch_group?
      return @owns_batch_group if defined?(@owns_batch_group)
      @owns_batch_group = BatchModeration::GroupSync.owned_batch_groups(user).exists?
    end
  end
end
