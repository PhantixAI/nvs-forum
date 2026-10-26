# frozen_string_literal: true
class CreateUrlExtractionRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :url_extraction_requests do |t|
      t.bigint :created_by_id, null: false
      t.string :url, null: false
      t.text :rules, null: false
      t.integer :status, null: false, default: 0
      t.text :csv_text
      t.jsonb :warnings, default: [], null: false
      t.text :error_message
      t.integer :rows_count
      t.timestamps
    end

    add_index :url_extraction_requests, %i[created_by_id created_at]
  end
end
