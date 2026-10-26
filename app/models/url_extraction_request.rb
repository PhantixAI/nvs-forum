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
  validates :rules, presence: true

  def self.statuses
    @statuses ||= Enum.new(queued: 0, processing: 1, ready: 2, failed: 3)
  end

  # A ready/failed request's csv_text can carry scraped roster PII
  # (names/emails) that shouldn't linger indefinitely once consumed or
  # abandoned -- mirrors UserExport::DESTROY_CREATED_BEFORE's own 2-day
  # window (see Jobs::CleanUpUrlExtractionRequests).
  DESTROY_CREATED_BEFORE = 2.days

  def self.remove_old
    where("created_at < ?", DESTROY_CREATED_BEFORE.ago).delete_all
  end
end
