# frozen_string_literal: true

# Not a core Discourse icon (unlike "shield"/"shield-halved" used elsewhere in
# this feature) -- must be registered before `dIcon` can render it.
DiscoursePluginRegistry.register_svg_icon("user-tie")

Rails.application.config.to_prepare do
  Group.register_custom_field_type(BatchModeration::GroupSync::CUSTOM_FIELD_FLAG, :boolean)

  if Guardian.ancestors.exclude?(BatchModeration::GuardianExtension)
    Guardian.prepend(BatchModeration::GuardianExtension)
  end
end

# Backgrounded (not called inline): a cohort change runs several UserField
# lookups plus, on top, the full Notifier pipeline (bulk insert + per-
# recipient job enqueue loop) -- real latency to add to every profile-save
# request if run synchronously in-request.
DiscourseEvent.on(:user_created) do |user|
  next if Thread.current[BatchModeration::GroupSync::DEFER_SYNC_ON_SIGNUP_THREAD_KEY]
  Jobs.enqueue(:sync_batch_moderation_group, user_id: user.id)
end

DiscourseEvent.on(:user_updated) do |user, _changed_columns|
  next if Thread.current[BatchModeration::GroupSync::DEFER_SYNC_ON_SIGNUP_THREAD_KEY]
  Jobs.enqueue(:sync_batch_moderation_group, user_id: user.id)
end
