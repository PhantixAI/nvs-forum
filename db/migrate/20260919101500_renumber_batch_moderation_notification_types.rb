# frozen_string_literal: true

# The batch moderation notification types were 46, 47 and 48, ids upstream
# Discourse hands out sequentially, so its next notification type would have
# shared one with them. They now live at 1001-1003 (Notification.types). The
# ids are written out here on purpose: this must keep working if the mapping in
# the model ever changes again. Safe to re-run -- once nothing is left at 46-48
# it changes nothing -- which also sweeps up any rows the previous release wrote
# while it was still serving traffic during a deploy.
class RenumberBatchModerationNotificationTypes < ActiveRecord::Migration[8.0]
  def up
    execute "UPDATE notifications SET notification_type = 1001 WHERE notification_type = 46"
    execute "UPDATE notifications SET notification_type = 1002 WHERE notification_type = 47"
    execute "UPDATE notifications SET notification_type = 1003 WHERE notification_type = 48"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
