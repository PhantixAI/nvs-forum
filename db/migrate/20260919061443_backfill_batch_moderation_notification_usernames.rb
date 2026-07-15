# frozen_string_literal: true

# These notifications link to /u/<username> using a username copied into their
# data when they were created, so any rename since then left the link dead.
# 46 = batch_moderation_action, 47 = batch_moderation_cohort_change,
# 48 = batch_moderation_status_change.
class BackfillBatchModerationNotificationUsernames < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE notifications
      SET data = (notifications.data::JSONB || jsonb_build_object('user_username', users.username))::JSON
      FROM users
      WHERE notifications.notification_type IN (47, 48)
        AND notifications.data::JSONB ->> 'user_id' = users.id::TEXT
        AND notifications.data::JSONB ->> 'user_username' IS DISTINCT FROM users.username
    SQL

    execute <<~SQL
      UPDATE notifications
      SET data = (notifications.data::JSONB || jsonb_build_object('target_username', users.username))::JSON
      FROM users
      WHERE notifications.notification_type = 46
        AND notifications.data::JSONB ->> 'target_user_id' = users.id::TEXT
        AND notifications.data::JSONB ->> 'target_username' IS DISTINCT FROM users.username
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
