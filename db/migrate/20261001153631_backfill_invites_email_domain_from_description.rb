# frozen_string_literal: true

# allow_any_email invites (and legacy rows predating that column) store the
# real intended address in `description` instead of `email`, so
# BackfillInvitesEmailDomain (which only read from `email`) never populated
# email_domain for them -- leaving them invisible to the domain filter and
# resend-by-domain feature. Backfills email_domain from description for
# exactly those rows, only when description is actually email-shaped.
class BackfillInvitesEmailDomainFromDescription < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BATCH_SIZE = 30_000
  # Mirrors EmailAddressValidator::EMAIL_REGEX's domain shape closely enough
  # for this backfill -- doesn't need to be byte-identical, just conservative
  # about not misreading a non-email description as one.
  EMAIL_SHAPED_SQL_REGEX =
    '^[^@[:space:]]+@([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$'

  def up
    loop do
      count = execute(<<~SQL).cmd_tuples
        WITH cte AS (
          SELECT id, lower(split_part(description, '@', 2)) AS domain
          FROM invites
          WHERE email_domain IS NULL
            AND email IS NULL
            AND description ~ '#{EMAIL_SHAPED_SQL_REGEX}'
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
