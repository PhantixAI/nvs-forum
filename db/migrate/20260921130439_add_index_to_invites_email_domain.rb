# frozen_string_literal: true

# invites is a large, busy table, and a plain CREATE INDEX blocks writes to it
# for as long as it takes to build, so this is done concurrently. Composite on
# (invited_by_id, email_domain) since every query filtering by domain already
# filters by inviter first.
class AddIndexToInvitesEmailDomain < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    remove_index :invites, %i[invited_by_id email_domain], algorithm: :concurrently, if_exists: true
    add_index :invites,
              %i[invited_by_id email_domain],
              where: "email_domain IS NOT NULL",
              algorithm: :concurrently
  end

  def down
    remove_index :invites, %i[invited_by_id email_domain], algorithm: :concurrently, if_exists: true
  end
end
