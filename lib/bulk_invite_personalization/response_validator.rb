# frozen_string_literal: true

module BulkInvitePersonalization
  # Defensive post-processing for AI-generated bulk invite note text. Returns a
  # sanitized String, or nil if the response violates one of the hard anti-spam
  # rules -- rejecting is deliberate here (vs. stripping and continuing), since
  # e.g. stripping a link out of a sentence can leave a broken fragment behind.
  module ResponseValidator
    MAX_WORDS = 75
    MIN_TRUNCATED_WORDS = 5

    URL_PATTERN = %r{https?://|www\.|\b[a-z0-9-]+\.(?:com|org|net|edu|io|co|ac\.in|in)\b}i
    MARKDOWN_PATTERN = /\*\*|`|\[.+?\]\(|^\s*[-*]\s|^\#{1,6}\s/
    SHOUTING_PATTERN = /!|\$|\b[A-Z]{4,}\b/
    SENTENCE_BOUNDARY = /[.?]/

    def self.clean(text)
      return nil if text.blank?

      text = ActionView::Base.full_sanitizer.sanitize(text)
      text = text.to_s.gsub(/\s+/, " ").strip
      return nil if text.blank?

      return nil if text.match?(URL_PATTERN)
      return nil if text.match?(MARKDOWN_PATTERN)
      return nil if text.match?(SHOUTING_PATTERN)

      truncate_to_word_limit(text)
    end

    def self.truncate_to_word_limit(text)
      words = text.split(" ")
      return text if words.length <= MAX_WORDS

      truncated = words.first(MAX_WORDS).join(" ")
      boundary = truncated.rindex(SENTENCE_BOUNDARY)
      return nil if boundary.nil?

      sentence = truncated[0..boundary].strip
      return nil if sentence.split(" ").length < MIN_TRUNCATED_WORDS

      sentence
    end
    private_class_method :truncate_to_word_limit
  end
end
