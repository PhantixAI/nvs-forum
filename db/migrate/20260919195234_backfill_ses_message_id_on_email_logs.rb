# frozen_string_literal: true

# Populates the new ses_message_id column (added in AddSesFieldsToEmailLogs)
# retroactively from smtp_transaction_response, which already captures SES's
# reply on every send ("250 Ok <ses-message-id>"). Without this, only emails
# sent after the column existed would ever be reconcilable against SES's
# bounce/delivery/complaint webhooks.
class BackfillSesMessageIdOnEmailLogs < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  BATCH_SIZE = 30_000

  def up
    loop do
      count = execute(<<~SQL).cmd_tuples
        WITH cte AS (
          SELECT id, substring(smtp_transaction_response from '^\\d+\\s+Ok\\s+(\\S+)') AS ses_id
          FROM email_logs
          WHERE ses_message_id IS NULL
            AND smtp_transaction_response ~ '^\\d+\\s+Ok\\s+\\S+'
          LIMIT #{BATCH_SIZE}
        )
        UPDATE email_logs
        SET ses_message_id = cte.ses_id
        FROM cte
        WHERE email_logs.id = cte.id
      SQL
      break if count == 0
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
