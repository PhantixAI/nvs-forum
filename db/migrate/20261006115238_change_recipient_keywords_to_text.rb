# frozen_string_literal: true

class ChangeRecipientKeywordsToText < ActiveRecord::Migration[8.1]
  def change
    change_column :invites, :recipient_keywords, :text
  end
end
