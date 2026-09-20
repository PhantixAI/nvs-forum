# frozen_string_literal: true

# The index on ses_message_id is added by AddIndexToEmailLogsSesMessageId,
# which builds it concurrently.
class AddSesFieldsToEmailLogs < ActiveRecord::Migration[8.0]
  def up
    add_column :email_logs, :ses_message_id, :string, null: true
    add_column :email_logs, :delivered_at, :datetime, null: true
    add_column :email_logs, :complained_at, :datetime, null: true
  end

  def down
    remove_column :email_logs, :ses_message_id if column_exists?(:email_logs, :ses_message_id)
    remove_column :email_logs, :delivered_at if column_exists?(:email_logs, :delivered_at)
    remove_column :email_logs, :complained_at if column_exists?(:email_logs, :complained_at)
  end
end
