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

DiscourseEvent.on(:user_created) do |user|
  next if Thread.current[BatchModeration::GroupSync::DEFER_SYNC_ON_SIGNUP_THREAD_KEY]
  BatchModeration::GroupSync.sync(user)
end

DiscourseEvent.on(:user_updated) do |user, _changed_columns|
  next if Thread.current[BatchModeration::GroupSync::DEFER_SYNC_ON_SIGNUP_THREAD_KEY]
  BatchModeration::GroupSync.sync(user)
end
