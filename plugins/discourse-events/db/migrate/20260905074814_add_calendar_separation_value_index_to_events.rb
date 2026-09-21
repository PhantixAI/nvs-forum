# frozen_string_literal: true
class AddCalendarSeparationValueIndexToEvents < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    # IF NOT EXISTS only skips an already-*valid* index -- if a concurrent build ever fails
    # partway (deadlock, canceled statement, anything that aborts mid-scan), Postgres leaves
    # an *invalid* index behind under this name, and every later CONCURRENTLY attempt
    # (including IF NOT EXISTS ones) errors out instead of skipping or repairing it. Drop any
    # leftover invalid index first, matching Postgres's own documented recovery for this.
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_discourse_post_event_events_calendar_separation_value"
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
