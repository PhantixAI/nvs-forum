# frozen_string_literal: true

class AddAiPersonalizationToInvites < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE invites ADD COLUMN ai_personalization BOOLEAN NOT NULL DEFAULT TRUE"
    execute "UPDATE invites SET ai_personalization = NOT skip_personalization"

    change_column_default :invites, :skip_personalization, nil
    Migration::ColumnDropper.mark_readonly(:invites, :skip_personalization)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
