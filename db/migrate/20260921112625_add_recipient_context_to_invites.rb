# frozen_string_literal: true

class AddRecipientContextToInvites < ActiveRecord::Migration[8.0]
  def up
    add_column :invites, :recipient_name, :string, limit: 100, null: true
    add_column :invites, :recipient_keywords, :string, limit: 255, null: true
  end

  def down
    remove_column :invites, :recipient_name if column_exists?(:invites, :recipient_name)
    remove_column :invites, :recipient_keywords if column_exists?(:invites, :recipient_keywords)
  end
end
