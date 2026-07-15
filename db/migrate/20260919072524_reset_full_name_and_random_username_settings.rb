# frozen_string_literal: true

# Full name is now always required at signup (which needs names enabled), and
# random usernames always on as the fallback for names that can't become a
# username. These settings are hidden from the admin UI, so drop any override
# that would keep an older, looser value in effect and let the defaults apply.
class ResetFullNameAndRandomUsernameSettings < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      DELETE FROM site_settings
      WHERE name IN ('full_name_requirement', 'enable_random_usernames', 'enable_names')
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
