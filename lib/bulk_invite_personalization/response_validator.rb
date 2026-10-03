# frozen_string_literal: true

module BulkInvitePersonalization
  # Defensive post-processing for an AI-generated bulk invite email (subject
  # and body are validated separately -- see Generator). Returns a sanitized
  # String, or nil if the response violates one of the hard anti-spam rules
  # -- rejecting is deliberate here (vs. stripping and continuing), since
  # e.g. stripping a link out of a sentence can leave a broken fragment
  # behind. Every rejection is logged (info level -- routine content
  # filtering, not a system error) so a silently-skipped personalization is
  # diagnosable from the logs, which it was not before.
  module ResponseValidator
    MAX_WORDS = 100
    MIN_TRUNCATED_WORDS = 5
    MAX_SUBJECT_WORDS = 12

    URL_PATTERN = %r{https?://|www\.|\b[a-z0-9-]+\.(?:com|org|net|edu|io|co|ac\.in|in)\b}i
    MARKDOWN_PATTERN = /\*\*|`|\[.+?\]\(|^\s*[-*]\s|^\#{1,6}\s/
    PUNCTUATION_SHOUTING_PATTERN = /!|\$/
    ALL_CAPS_WORD_PATTERN = /\b[A-Z]{4,}\b/
    SENTENCE_BOUNDARY = /[.?]/
    REQUIRED_LINK_LINE = "\n\nPlease use the following invite link to join the forum:\n%{link}"

    # The model is told not to write the join link itself (see
    # Generator#system_message) -- it is always appended here afterward,
    # verbatim, on its own line, never left to the model to place or
    # format. Reliably getting an LLM to reproduce a URL, with exact
    # formatting and no typos, on every single call isn't something worth
    # depending on; this also means any link-shaped text at all in the
    # model's own output is unexpected (see the URL check below), not
    # something to make an exception for.
    def self.clean_body(text, required_link:, invite_id: nil, recipient_domain: nil)
      return nil if text.blank?

      sanitized = ActionView::Base.full_sanitizer.sanitize(text).to_s
      return nil if sanitized.blank?

      # Checked against the original line breaks, before they're collapsed below --
      # collapsing first would merge every line into one, so Ruby's per-line ^/$
      # anchors in MARKDOWN_PATTERN could then only ever match a bullet/heading
      # that happened to be the very first character of the whole response. A
      # model that appends a self-check list after the real note (observed in
      # production: "* 3-4 sentences max? Exactly 3 sentences. * No links...")
      # starts those bullets partway through the text, so they'd slip through.
      if sanitized.match?(MARKDOWN_PATTERN)
        log_rejection(:body, "markdown formatting", invite_id:, text: sanitized)
        return nil
      end

      flattened = collapse_whitespace(sanitized, preserve_paragraphs: true)
      return nil if flattened.blank?

      if contains_unexpected_link?(flattened, recipient_domain)
        log_rejection(:body, "unexpected link or domain", invite_id:, text: flattened)
        return nil
      end

      if (word = shouting_word(flattened))
        log_rejection(:body, "shouting (word: #{word.inspect})", invite_id:, text: flattened)
        return nil
      end

      truncated = truncate_to_word_limit(flattened)
      if truncated.nil?
        log_rejection(
          :body,
          "over the word limit with no clean sentence boundary",
          invite_id:,
          text: flattened,
        )
        return nil
      end

      "#{truncated}#{REQUIRED_LINK_LINE % { link: required_link }}"
    end

    def self.clean_subject(text, invite_id: nil, recipient_domain: nil)
      return nil if text.blank?

      sanitized = ActionView::Base.full_sanitizer.sanitize(text).to_s
      return nil if sanitized.blank?

      if sanitized.match?(MARKDOWN_PATTERN)
        log_rejection(:subject, "markdown formatting", invite_id:, text: sanitized)
        return nil
      end

      flattened = collapse_whitespace(sanitized)
      return nil if flattened.blank?

      if contains_unexpected_link?(flattened, recipient_domain)
        log_rejection(:subject, "contains a link or domain", invite_id:, text: flattened)
        return nil
      end

      if (word = shouting_word(flattened))
        log_rejection(:subject, "shouting (word: #{word.inspect})", invite_id:, text: flattened)
        return nil
      end

      if flattened.split(" ").length > MAX_SUBJECT_WORDS
        log_rejection(:subject, "over #{MAX_SUBJECT_WORDS} words", invite_id:, text: flattened)
        return nil
      end

      flattened
    end

    # The model is explicitly told it may reference the recipient's
    # college/institution using their bare email domain when it doesn't
    # know the real institution name (see Generator's rules) -- a prose
    # mention of exactly that domain is not a link and must not be
    # rejected as one. Only the bare substring is stripped before
    # checking, so an actual http://<domain> or www.<domain> construction
    # of the same domain still matches URL_PATTERN on what's left and is
    # still rejected -- only a plain mention is exempt.
    def self.contains_unexpected_link?(text, recipient_domain)
      checked = recipient_domain.present? ? text.gsub(recipient_domain, "") : text
      checked.match?(URL_PATTERN)
    end
    private_class_method :contains_unexpected_link?

    # A blanket gsub(/\s+/, " ") (the old behavior, still used for the
    # single-line subject) would also flatten an intentional blank-line
    # paragraph break into a single space, silently merging a model's
    # multi-paragraph body into one paragraph -- the same class of bug as
    # the earlier newline-before-link issue. preserve_paragraphs: true
    # (used for the body) keeps each blank-line-separated chunk distinct:
    # whitespace is still collapsed *within* each paragraph, but the break
    # *between* paragraphs survives as its own "\n\n".
    def self.collapse_whitespace(text, preserve_paragraphs: false)
      return text.gsub(/\s+/, " ").strip unless preserve_paragraphs

      text
        .split(/\n\s*\n/)
        .map { |paragraph| paragraph.gsub(/\s+/, " ").strip }
        .reject(&:blank?)
        .join("\n\n")
    end
    private_class_method :collapse_whitespace

    # Returns the specific offending word (for the log line) rather than a
    # bare true/false, so a rejection log says *what* tripped it instead of
    # just that something did -- the difference between re-running this by
    # hand to find out and reading it straight off the log line.
    def self.shouting_word(text)
      return "!/$" if text.match?(PUNCTUATION_SHOUTING_PATTERN)

      allowlist = SiteSetting.institute_acronyms.split("|")
      text
        .scan(ALL_CAPS_WORD_PATTERN)
        .find do |word|
          # Confirmed in production: the model routinely writes the natural
          # plural ("NITS" for an allow-listed "NIT") rather than the bare
          # acronym -- an otherwise-compliant response was being rejected as
          # shouting for that alone. Tolerate a simple trailing-S plural of
          # any allow-listed acronym rather than requiring an exact match.
          !allowlist.include?(word) && !allowlist.include?(word.chomp("S"))
        end
    end
    private_class_method :shouting_word

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

    # text is truncated in the log line, not omitted -- enough to recognize
    # the response without the log line itself becoming the next thing that
    # needs truncating. Full text is still in AiApiAuditLog if needed.
    def self.log_rejection(field, reason, invite_id:, text:)
      Rails.logger.info(
        "[BulkInvitePersonalization] invite #{invite_id}: rejected (#{field}): #{reason} -- text[0..150]=#{text[0..150].inspect}",
      )
    end
    private_class_method :log_rejection
  end
end
