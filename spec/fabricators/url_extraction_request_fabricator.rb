# frozen_string_literal: true

Fabricator(:url_extraction_request) do
  created_by(fabricator: :admin)
  url "https://example.edu/students"
  rules "Extract email and name"
end
