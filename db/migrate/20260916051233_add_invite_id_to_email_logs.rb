# frozen_string_literal: true

class AddInviteIdToEmailLogs < ActiveRecord::Migration[8.0]
  def up
    add_column :email_logs, :invite_id, :integer, null: true
    add_index :email_logs, :invite_id, where: "invite_id IS NOT NULL"
  end

  def down
    remove_index :email_logs, :invite_id if index_exists?(:email_logs, [:invite_id])
    remove_column :email_logs, :invite_id if column_exists?(:email_logs, :invite_id)
  end
end
