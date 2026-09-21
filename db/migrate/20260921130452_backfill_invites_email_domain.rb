# frozen_string_literal: true

# Populates the new email_domain column (added in AddEmailDomainToInvites)
# retroactively from email, so the domain filter/resend feature covers
# existing invites, not just ones created after this column existed.
class BackfillInvitesEmailDomain < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  BATCH_SIZE = 30_000

  def up
    loop do
      count = execute(<<~SQL).cmd_tuples
        WITH cte AS (
          SELECT id, split_part(email, '@', 2) AS domain
          FROM invites
          WHERE email_domain IS NULL
            AND email IS NOT NULL
          LIMIT #{BATCH_SIZE}
        )
        UPDATE invites
        SET email_domain = cte.domain
        FROM cte
        WHERE invites.id = cte.id
      SQL
      break if count == 0
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
