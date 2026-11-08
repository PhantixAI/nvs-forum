# frozen_string_literal: true
class AddLastEmailedStatusToInvites < ActiveRecord::Migration[8.1]
  def change
    add_column :invites, :last_emailed_status, :integer, null: true
  end
end
