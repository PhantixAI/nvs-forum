# frozen_string_literal: true

# Tracks one admin-submitted "Extract from URL" request, letting the
# extraction run off the HTTP request cycle (see
# Jobs::ProcessUrlExtractionRequest) and letting an admin submit several
# URLs back-to-back without waiting on each one -- InvitesController#
# extract_from_url used to run BulkInviteUrlExtraction::Generator.extract
# synchronously, which could exceed a reverse proxy's gateway timeout on a
# dense page even with that module's own bounded concurrency.
class UrlExtractionRequest < ActiveRecord::Base
  belongs_to :created_by, class_name: "User"

  validates :url, presence: true
  validates :rules, presence: true, unless: -> { status == self.class.statuses[:draft] }

  # Matches Jobs::ProcessUrlExtractionRequest::CHANNEL -- shared here so
  # both that job and InvitesController#create_drafts (which flips a
  # request to :closed) can push a live update from one place.
  PROGRESS_CHANNEL = "/url-extraction-progress"

  def self.statuses
    # :closed -- an admin has created drafts from this request's CSV (see
    # InvitesController#create_drafts). Distinct from :ready so the
    # Extracted tab can show at a glance which requests still need review
    # vs. which have already been acted on, even if every row in that CSV
    # ended up skipped as a duplicate.
    #
    # :draft -- saved by InvitesController#extract_from_url with no rules
    # yet, so an admin can come back and write them later (see
    # UrlExtractionRetryModal, reused unchanged for this). Never enqueued
    # into Jobs::ProcessUrlExtractionRequest -- see that enqueue call's own
    # comment -- and excluded from .remove_old below, since it has no
    # csv_text (nothing extracted yet) to age out.
    @statuses ||= Enum.new(queued: 0, processing: 1, ready: 2, failed: 3, closed: 4, draft: 5)
  end

  def broadcast_progress!
    MessageBus.publish(
      PROGRESS_CHANNEL,
      { request: UrlExtractionRequestSerializer.new(self, root: false).as_json },
      user_ids: [created_by_id],
    )
  end

  # A ready/failed request's csv_text can carry scraped roster PII
  # (names/emails) that shouldn't linger indefinitely once consumed or
  # abandoned -- mirrors UserExport::DESTROY_CREATED_BEFORE's own 2-day
  # window (see Jobs::CleanUpUrlExtractionRequests).
  DESTROY_CREATED_BEFORE = 2.days

  # :draft is exempt -- it's deliberately long-lived (an admin may take
  # well over 2 days to get around to writing its rules) and carries no
  # PII of its own: nothing has been extracted from it yet.
  def self.remove_old
    where("created_at < ?", DESTROY_CREATED_BEFORE.ago)
      .where.not(status: statuses[:draft])
      .delete_all
  end
end
