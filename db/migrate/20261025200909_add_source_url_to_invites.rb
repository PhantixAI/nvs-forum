# frozen_string_literal: true
class AddSourceUrlToInvites < ActiveRecord::Migration[8.1]
  def change
    add_column :invites, :source_url, :string, limit: 2048
  end
end
