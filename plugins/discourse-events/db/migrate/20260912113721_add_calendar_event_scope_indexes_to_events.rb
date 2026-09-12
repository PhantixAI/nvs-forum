# frozen_string_literal: true
class AddCalendarEventScopeIndexesToEvents < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_discourse_post_event_events_calendar_event_scope"
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_discourse_post_event_events_calendar_event_scope
      ON discourse_post_event_events ((custom_fields ->> '_calendar_event_scope'))
    SQL

    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_discourse_post_event_events_calendar_batch_cohort_digest"
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_discourse_post_event_events_calendar_batch_cohort_digest
      ON discourse_post_event_events ((custom_fields ->> '_calendar_batch_cohort_digest'))
      WHERE (custom_fields ->> '_calendar_batch_cohort_digest') IS NOT NULL
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_discourse_post_event_events_calendar_event_scope"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_discourse_post_event_events_calendar_batch_cohort_digest"
  end
end
