# frozen_string_literal: true
class AddScheduleSendToInvites < ActiveRecord::Migration[8.1]
  def change
    add_column :invites, :schedule_send, :boolean, default: true, null: false
  end
end
