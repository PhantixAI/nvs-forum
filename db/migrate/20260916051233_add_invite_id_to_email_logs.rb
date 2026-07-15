# frozen_string_literal: true

# The index on invite_id is added by AddIndexToEmailLogsInviteId, which builds
# it concurrently.
class AddInviteIdToEmailLogs < ActiveRecord::Migration[8.0]
  def up
    add_column :email_logs, :invite_id, :integer, null: true
  end

  def down
    remove_column :email_logs, :invite_id if column_exists?(:email_logs, :invite_id)
  end
end
