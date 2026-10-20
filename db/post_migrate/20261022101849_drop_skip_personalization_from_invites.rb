# frozen_string_literal: true

class DropSkipPersonalizationFromInvites < ActiveRecord::Migration[8.1]
  DROPPED_COLUMNS = { invites: %i[skip_personalization] }

  def up
    DROPPED_COLUMNS.each { |table, columns| Migration::ColumnDropper.execute_drop(table, columns) }
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
