# frozen_string_literal: true

class AddAllowAnyEmailToInvites < ActiveRecord::Migration[8.0]
  def change
    add_column :invites, :allow_any_email, :boolean, default: false, null: false
  end
end
