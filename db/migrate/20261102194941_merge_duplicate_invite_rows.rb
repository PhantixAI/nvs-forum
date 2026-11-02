# frozen_string_literal: true

# Invite#make_shareable! (the admin "Shareable link" toggle on Resend/Send
# Invites) had no dedupe check of its own, and the bulk resend action calls
# it once per matched invite with no cross-row check either -- so running
# it over a filtered batch that happened to contain two historical invite
# rows for the same person (one bound, one already a link, or two bound
# rows from separate CSV uploads) converted both independently into two
# separate "shareable link" rows with the identical description, instead of
# one. This merges every such group that's already on the books: for each
# (inviter, recipient) pair with more than one live row, the row with the
# most redemptions (then the most recently created) is kept and the rest
# are soft-deleted (trashed, not destroyed, so this is reversible) -- but
# only when every row being removed has zero redemptions of its own, so a
# duplicate someone has actually redeemed through is never silently folded
# away. See app/models/invite.rb Invite#make_shareable! / .find_duplicate_for
# for the matching code fix that stops this from recurring.
class MergeDuplicateInviteRows < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      WITH ranked AS (
        SELECT
          id,
          ROW_NUMBER() OVER (
            PARTITION BY invited_by_id, lower(description)
            ORDER BY redemption_count DESC, created_at DESC, id DESC
          ) AS rn
        FROM invites
        WHERE deleted_at IS NULL
          AND allow_any_email = TRUE
          AND description IS NOT NULL
      )
      UPDATE invites
      SET deleted_at = NOW(), deleted_by_id = -1
      FROM ranked
      WHERE invites.id = ranked.id
        AND ranked.rn > 1
        AND invites.redemption_count = 0
    SQL

    execute <<~SQL
      WITH ranked AS (
        SELECT
          id,
          ROW_NUMBER() OVER (
            PARTITION BY invited_by_id, lower(email)
            ORDER BY redemption_count DESC, created_at DESC, id DESC
          ) AS rn
        FROM invites
        WHERE deleted_at IS NULL
          AND email IS NOT NULL
      )
      UPDATE invites
      SET deleted_at = NOW(), deleted_by_id = -1
      FROM ranked
      WHERE invites.id = ranked.id
        AND ranked.rn > 1
        AND invites.redemption_count = 0
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
