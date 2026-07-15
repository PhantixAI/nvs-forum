# frozen_string_literal: true

# email_logs is one of the largest tables, and a plain CREATE INDEX blocks
# writes to it (every outgoing email) for as long as it takes to build, so this
# is done concurrently. remove_index first because SafeMigrate requires it.
class AddIndexToEmailLogsSesMessageId < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    remove_index :email_logs, :ses_message_id, algorithm: :concurrently, if_exists: true
    add_index :email_logs,
              :ses_message_id,
              where: "ses_message_id IS NOT NULL",
              algorithm: :concurrently
  end

  def down
    remove_index :email_logs, :ses_message_id, algorithm: :concurrently, if_exists: true
  end
end
