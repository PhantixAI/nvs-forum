# frozen_string_literal: true

class AddSkipPersonalizationToInvites < ActiveRecord::Migration[8.0]
  def change
    add_column :invites, :skip_personalization, :boolean, default: false, null: false
  end
end
