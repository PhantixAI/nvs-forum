# frozen_string_literal: true

module Jobs
  # Runs BulkInviteUrlExtraction::Generator.extract off the HTTP request
  # cycle -- even with that module's own 4-way chunk concurrency, a page
  # with many chunks can cumulatively exceed a reverse proxy's gateway
  # timeout before a synchronous response completes. Runs on Sidekiq's
  # normal worker pool, no extra concurrency cap of its own -- each enqueue
  # here is already one full, internally-bounded Generator.extract call,
  # not a batch needing its own throttle (unlike
  # Jobs::GenerateInvitePersonalization, which processes many invites per
  # enqueue). No RailsMultisite handling needed here either: this job never
  # spawns its own threads (Generator.extract's bare Thread.new calls
  # already re-establish multisite context around themselves).
  class ProcessUrlExtractionRequest < ::Jobs::Base
    sidekiq_options retry: false

    CHANNEL = UrlExtractionRequest::PROGRESS_CHANNEL

    def execute(args)
      request = UrlExtractionRequest.find_by(id: args[:request_id])
      return if request.nil?

      request.update!(status: UrlExtractionRequest.statuses[:processing])

      begin
        result = BulkInviteUrlExtraction::Generator.extract(url: request.url, rules: request.rules)
        request.update!(
          status: UrlExtractionRequest.statuses[:ready],
          csv_text: build_csv(result.rows),
          warnings: result.warnings,
          rows_count: result.rows.size,
        )
      rescue BulkInviteUrlExtraction::Generator::ExtractionFailed => e
        request.update!(status: UrlExtractionRequest.statuses[:failed], error_message: e.message)
      rescue StandardError => e
        Rails.logger.error(
          "[ProcessUrlExtractionRequest] request #{request.id} failed unexpectedly -- #{e.class}: #{e.message}",
        )
        request.update!(
          status: UrlExtractionRequest.statuses[:failed],
          error_message: "Something went wrong while extracting this page.",
        )
      end

      request.broadcast_progress!
    end

    private

    # Same CSV shape the frontend used to build client-side
    # (email,name,groups,topic_id,locale,keywords; rules broadcast into
    # every row's keywords cell) -- built server-side now since the client
    # never sees raw `rows` anymore.
    def build_csv(rows)
      header = %w[email name groups topic_id locale keywords]
      lines = [header.join(",")]
      rows.each do |row|
        lines << [row[:email], row[:name], "", "", "en", row[:keywords]].map { |v| csv_field(v) }
          .join(",")
      end
      lines.join("\n")
    end

    def csv_field(value)
      text = value.to_s
      /["\n,]/.match?(text) ? "\"#{text.gsub('"', '""')}\"" : text
    end
  end
end
