# frozen_string_literal: true

class UrlExtractionRequestSerializer < ApplicationSerializer
  attributes :id,
             :url,
             :rules,
             :status,
             :csv_text,
             :warnings,
             :error_message,
             :rows_count,
             :created_at

  def status
    UrlExtractionRequest.statuses[object.status]
  end
end
