# frozen_string_literal: true

module Jobs
  class CleanUpUrlExtractionRequests < ::Jobs::Scheduled
    every 1.day

    def execute(_args)
      UrlExtractionRequest.remove_old
    end
  end
end
