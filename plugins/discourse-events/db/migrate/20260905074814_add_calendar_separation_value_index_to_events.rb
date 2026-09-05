# frozen_string_literal: true
class AddCalendarSeparationValueIndexToEvents < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_discourse_post_event_events_calendar_separation_value
      ON discourse_post_event_events ((custom_fields ->> '_calendar_separation_value'))
      WHERE (custom_fields ->> '_calendar_separation_value') IS NOT NULL
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_discourse_post_event_events_calendar_separation_value"
  end
end
