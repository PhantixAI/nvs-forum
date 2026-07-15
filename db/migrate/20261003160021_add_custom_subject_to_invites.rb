# frozen_string_literal: true
class AddCustomSubjectToInvites < ActiveRecord::Migration[8.1]
  def change
    add_column :invites, :custom_subject, :string
  end
end
