# frozen_string_literal: true

# Restricted, directory-like row serializer used when a non-staff Batch
# Moderator views the admin users list, scoped to their own cohort
# (Admin::UsersController#index_for_batch_moderator). Deliberately does not
# inherit from AdminUserListSerializer, even with conditional include_*?
# gating -- a separate class means there's no risk of a staff-only field
# (email, IP data, suspend/silence reasons, etc.) leaking through via a
# missed branch.
class BatchModeratorUserListSerializer < BasicUserSerializer
  # :username and :avatar_template are already declared by BasicUserSerializer
  attributes :trust_level, :created_at, :last_seen_at, :is_batch_moderator

  def is_batch_moderator
    @options[:batch_moderator_user_ids]&.include?(object.id) || false
  end
end
