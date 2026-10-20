# frozen_string_literal: true

module Jobs
  # Pre-generates AI-personalized content for a batch of invites *before*
  # they ever reach Jobs::ProcessBulkInviteEmails' paced send queue --
  # splitting "generate the email" from "send the email" so a slow/variable
  # LLM call (confirmed in production: anywhere from ~3s to 367s per call)
  # can no longer block that queue's per-invite send pacing, which is what
  # happened when personalization ran inline inside
  # Jobs::ProcessBulkInviteEmails#deliver. Enqueued by
  # InvitesController#dispatch_bulk_resend (Send Selected drafts, Resend All
  # with personalize+schedule both on) and Jobs::BulkInvite (a CSV upload row
  # with ai_personalization/schedule_send both on).
  #
  # Claims every given invite id into :drafting up front (skipping any
  # already mid-flight elsewhere -- see #claim_for_drafting), then works
  # through them in small concurrent thread batches, mirroring
  # BulkInviteUrlExtraction::Generator#extract's own thread-batching pattern
  # (each thread re-establishes this job's multisite db connection, since a
  # bare Thread.new would otherwise run against the wrong site's database).
  # Each invite that resolves (personalized, or confirmed not applicable)
  # flips straight to :bulk_pending, and ::Jobs::ProcessBulkInviteEmails
  # .ensure_chain! is nudged once per batch slice -- not only once at the
  # end -- so invites from an earlier slice can start sending while a later
  # slice is still generating. A failure for one invite marks only that
  # invite :skipped and never aborts the rest of its thread batch or the job.
  class GenerateInvitePersonalization < ::Jobs::Base
    def execute(args)
      invite_ids = Array(args[:invite_ids]).map(&:to_i)
      return if invite_ids.blank?

      extra_keywords = args[:extra_keywords]
      claimed_ids = claim_for_drafting(invite_ids)
      return if claimed_ids.empty?

      current_db = RailsMultisite::ConnectionManagement.current_db
      max_concurrent = SiteSetting.bulk_invite_personalization_max_concurrency

      claimed_ids.each_slice(max_concurrent) do |batch_ids|
        threads =
          batch_ids.map do |invite_id|
            Thread.new { generate_safely(invite_id, extra_keywords, current_db) }
          end

        ::Jobs::ProcessBulkInviteEmails.ensure_chain! if threads.count { |thread| thread.value } > 0
      end
    end

    private

    # A single conditional UPDATE, not a find_each+save loop -- so two
    # overlapping enqueues of this job (e.g. an admin double-clicking "Send
    # Selected") can't both claim, and both regenerate content for, the same
    # invite. Mirrors Invite.claim_for_immediate_send's same reasoning.
    #
    # "emailed_status IS NULL OR ..." -- not just a plain where.not, which
    # would silently exclude every NULL row instead of claiming it: SQL's
    # NOT IN against NULL evaluates to NULL (neither true nor false), so a
    # row with no emailed_status set yet would never be claimable without
    # this. Invite.pending/.expired already guard against this same gap.
    def claim_for_drafting(invite_ids)
      in_flight_statuses = Invite.emailed_status_types.values_at(:drafting, :bulk_pending, :sending)

      claimable_ids =
        Invite
          .where(id: invite_ids)
          .where("emailed_status IS NULL OR emailed_status NOT IN (?)", in_flight_statuses)
          .pluck(:id)
      return [] if claimable_ids.empty?

      Invite.where(id: claimable_ids).update_all(
        emailed_status: Invite.emailed_status_types[:drafting],
        updated_at: Time.zone.now,
      )
      claimable_ids
    end

    # Runs on its own thread (see #execute), re-establishing this job's
    # multisite db/connection there -- same reasoning as
    # BulkInviteUrlExtraction::Generator#extract_chunk_safely. Returns
    # true/false (not the personalize result) so #execute can cheaply count
    # how many of this slice actually produced a new :bulk_pending invite,
    # deciding whether to nudge the chain for that slice.
    def generate_safely(invite_id, extra_keywords, db)
      RailsMultisite::ConnectionManagement.with_connection(db) do
        invite = Invite.find_by(id: invite_id)
        next false if invite.nil?

        result = BulkInvitePersonalization::Generator.personalize(invite, extra_keywords:)
        # A nil result means personalization doesn't apply (feature off, no
        # template, no LLM configured) -- must not wipe an existing
        # custom_subject/custom_message, and the invite still becomes
        # bulk_pending either way (it just sends with whatever it already
        # had, same as Jobs::ProcessBulkInviteEmails#deliver used to handle
        # a nil result).
        invite.update_columns(
          custom_subject: result&.fetch(:subject) || invite.custom_subject,
          custom_message: result&.fetch(:body) || invite.custom_message,
          emailed_status: Invite.emailed_status_types[:bulk_pending],
        )
        true
      end
    rescue BulkInvitePersonalization::Generator::GenerationFailed => e
      Rails.logger.error(
        "[GenerateInvitePersonalization] invite #{invite_id} skipped -- #{e.message}",
      )
      mark_skipped(invite_id, db)
      false
    rescue StandardError => e
      # Generator.personalize already converts its own failures into
      # GenerationFailed (see its class comment) -- this only catches
      # something going wrong around that call (e.g. the update_columns
      # write itself). Rescued here, not left to propagate out of the
      # Thread.new block, since an unhandled exception there would only
      # surface later when #execute calls thread.value, aborting the whole
      # batch (including slices that already succeeded) rather than just
      # this one invite.
      Rails.logger.error(
        "[GenerateInvitePersonalization] invite #{invite_id} failed unexpectedly -- #{e.class}: #{e.message}",
      )
      mark_skipped(invite_id, db)
      false
    end

    def mark_skipped(invite_id, db)
      RailsMultisite::ConnectionManagement.with_connection(db) do
        Invite.where(id: invite_id).update_all(
          emailed_status: Invite.emailed_status_types[:skipped],
        )
      end
    end
  end
end
