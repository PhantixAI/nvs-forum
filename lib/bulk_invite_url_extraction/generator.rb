# frozen_string_literal: true

module BulkInviteUrlExtraction
  # Fetches an admin-supplied URL and asks the site's configured AI language
  # model to extract a list of {email, name, keywords} rows from it,
  # following admin-provided free-text rules (e.g. "emails are printed
  # directly", "build the email by appending RollNo to @example.edu", or
  # "use Department, Program, Advisor as keywords" -- the rules can drive
  # per-row keywords the same way they drive email/name). Used to seed the
  # admin-editable CSV review step ahead of draft-invite creation
  # (BulkInviteUrlExtraction::DraftCreator) -- this module never creates an
  # Invite or sends anything itself.
  module Generator
    ExtractionFailed = Class.new(StandardError)

    # How much fetched page text goes into a single LLM call's input --
    # independent of bulk_invite_url_extraction_max_tokens, which bounds that
    # call's *output* (the extracted rows), not what it's shown. A page
    # longer than this is split into multiple calls (see #chunk_by_line) so a
    # long roster doesn't get silently truncated before every row is seen.
    CHUNK_CHAR_BUDGET = 12_000

    # Chunks are extracted concurrently (see #extract) rather than one after
    # another, since a page that splits into several chunks (e.g. a 200+ row
    # roster) otherwise has to complete that many sequential LLM calls
    # before the request can respond -- long enough on a dense page to trip
    # a reverse proxy's gateway timeout even though no single call is slow.
    # This caps how many of those calls run at once, since each holds its
    # own multisite db connection (for its AiApiAuditLog row and
    # SiteSetting reads -- see #extract_chunk_safely) for the duration.
    MAX_CONCURRENT_CHUNKS = 4

    # A GitHub-flavored-markdown pipe-table separator row, e.g. "| --- | --- |"
    # -- this is exactly what WebPageFetcher#table_to_markdown emits for an
    # HTML <table>, used below to detect a table's header so it can be
    # repeated into later chunks of the same table.
    TABLE_SEPARATOR_PATTERN = /\A\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*\z/

    ROW_SCHEMA = {
      type: "json_schema",
      json_schema: {
        name: "extracted_invite_rows",
        strict: true,
        schema: {
          type: "object",
          properties: {
            rows: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  email: {
                    type: "string",
                  },
                  name: {
                    type: "string",
                  },
                  keywords: {
                    type: "string",
                  },
                },
                required: %w[email name keywords],
                additionalProperties: false,
              },
            },
          },
          required: %w[rows],
          additionalProperties: false,
        },
      },
    }

    Result = Struct.new(:rows, :warnings, keyword_init: true)

    # Raises ExtractionFailed only when nothing at all could be extracted
    # (feature disabled, no LLM configured, the page couldn't be fetched, or
    # every chunk's extraction call failed) -- this feeds an admin-reviewed
    # preview, not a send, so a partial result (with warnings) from a large
    # page where one section failed is more useful than discarding the whole
    # run over that one section.
    def self.extract(url:, rules:)
      raise ExtractionFailed, "AI extraction is not enabled" unless enabled?

      llm = resolve_llm
      raise ExtractionFailed, "No AI language model is configured" if llm.nil?

      text = fetch_page_text(url)
      chunks = chunk_by_line(text, CHUNK_CHAR_BUDGET)

      # Captured on the request thread and re-applied inside each spawned
      # thread below -- RailsMultisite::ConnectionManagement's db selection
      # is per-thread state (see Scheduler::Deferrable#later for the same
      # pattern), so a bare Thread.new here would silently run against the
      # "default" site's database/settings instead of this request's site.
      current_db = RailsMultisite::ConnectionManagement.current_db

      rows = []
      warnings = []
      chunks
        .each_with_index
        .each_slice(MAX_CONCURRENT_CHUNKS) do |batch|
          threads =
            batch.map do |chunk, index|
              Thread.new do
                extract_chunk_safely(llm, chunk, rules, index, chunks.size, url, current_db)
              end
            end

          threads.each do |thread|
            result = thread.value
            if result[:warning]
              warnings << result[:warning]
            else
              rows.concat(result[:rows])
            end
          end
        end

      if rows.empty? && warnings.present?
        raise ExtractionFailed, "No rows could be extracted -- #{warnings.join(" ")}"
      end

      Result.new(rows: dedupe(rows), warnings: warnings)
    end

    def self.enabled?
      defined?(DiscourseAi) && SiteSetting.discourse_ai_enabled &&
        SiteSetting.bulk_invite_url_extraction_enabled
    end
    private_class_method :enabled?

    def self.resolve_llm
      model_id = SiteSetting.ai_default_llm_model
      model = model_id.present? ? LlmModel.find_by(id: model_id) : LlmModel.last
      model&.to_llm
    end
    private_class_method :resolve_llm

    def self.fetch_page_text(url)
      result = DiscourseAi::Rag::WebPageFetcher.fetch(url: url, etag: nil, last_modified: nil)
      text = result[:text]
      raise ExtractionFailed, "The page did not contain any readable text" if text.blank?

      text
    rescue DiscourseAi::Rag::WebPageFetcher::FetchError => e
      raise ExtractionFailed, "Could not fetch the page: #{e.message}"
    end
    private_class_method :fetch_page_text

    # Splits on line boundaries only (never mid-line), so a markdown table
    # row is never split across two LLM calls. While walking through a
    # table's rows, the most recently seen header (the row immediately above
    # a "| --- | --- |" separator, plus the separator itself) is repeated at
    # the top of any later chunk that starts partway through that same
    # table, so the model still has the column meanings for a long roster
    # split across several chunks.
    def self.chunk_by_line(text, char_budget)
      chunks = []
      current = +""
      current_size = 0
      table_header = nil
      in_table = false
      previous_line = nil

      text.each_line do |line|
        if !in_table && previous_line && line.match?(TABLE_SEPARATOR_PATTERN)
          table_header = +"#{previous_line}#{line}"
          in_table = true
        elsif in_table && !line.lstrip.start_with?("|")
          in_table = false
        end

        if current.present? && current_size + line.length > char_budget
          chunks << current
          current = in_table && table_header ? table_header.dup : +""
          current_size = current.length
        end

        current << line
        current_size += line.length
        previous_line = line
      end

      chunks << current if current.present?
      chunks
    end
    private_class_method :chunk_by_line

    # Runs on its own thread (see #extract), re-establishing the request's
    # multisite db/connection there -- extract_chunk's LLM call writes an
    # AiApiAuditLog row, and reads SiteSetting, neither of which a bare
    # thread would otherwise resolve against the right site. Turns a
    # failed call into the same per-chunk warning the old serial loop
    # produced, instead of raising out of the thread and losing the whole
    # batch.
    def self.extract_chunk_safely(llm, chunk_text, rules, index, chunk_count, url, db)
      rows =
        RailsMultisite::ConnectionManagement.with_connection(db) do
          extract_chunk(llm, chunk_text, rules)
        end
      { rows: rows }
    rescue StandardError => e
      Rails.logger.warn(
        "[BulkInviteUrlExtraction] chunk #{index + 1}/#{chunk_count} failed for #{url}: #{e.class}: #{e.message}",
      )
      { warning: "Part #{index + 1} of #{chunk_count} of the page could not be processed." }
    end
    private_class_method :extract_chunk_safely

    def self.extract_chunk(llm, chunk_text, rules)
      prompt =
        DiscourseAi::Completions::Prompt.new(
          system_message(rules),
          messages: [{ type: :user, content: chunk_text }],
        )

      response = +""
      llm.generate(
        prompt,
        user: Discourse.system_user,
        feature_name: "bulk_invite_url_extraction",
        max_tokens: SiteSetting.bulk_invite_url_extraction_max_tokens,
        thinking_effort: "none",
        response_format: ROW_SCHEMA,
      ) do |partial|
        if partial.is_a?(DiscourseAi::Completions::StructuredOutput)
          response = partial
        elsif partial.is_a?(String) && response.is_a?(String)
          response << partial
        end
      end

      raw_rows =
        if response.is_a?(DiscourseAi::Completions::StructuredOutput)
          # read_buffered_property tracks the best-effort-completed value of
          # "rows" as it streamed in, so if the model's JSON got cut off
          # (typically by max_tokens on a dense chunk) before it could close,
          # this still returns whatever complete rows exist before the
          # cutoff instead of losing the whole chunk to a raw JSON.parse
          # failure on the still-truncated text.
          response.read_buffered_property(:rows)
        else
          JSON.parse(
            DiscourseAi::Completions::Llm.text_from_response(response),
            symbolize_names: true,
          )[
            :rows
          ]
        end

      Array(raw_rows).filter_map do |row|
        row = row.is_a?(Hash) ? row.transform_keys(&:to_sym) : {}
        email = row[:email].to_s.strip
        next if email.blank?

        { email: email, name: row[:name].to_s.strip, keywords: row[:keywords].to_s.strip }
      end
    end
    private_class_method :extract_chunk

    def self.system_message(rules)
      <<~TEXT
        You extract a list of people from a webpage's text content, as rows
        of {email, name, keywords}. The user message contains one section of
        that page -- it may be a partial table or list, cut off at either
        end; extract whatever complete rows it contains.

        Follow these admin-provided extraction rules exactly:

        #{rules}

        Only include a row if you can determine, or construct per the rules
        above, a real email address. Never invent an email address the rules
        don't support constructing.

        The rules may also say what to use as each row's "keywords" value --
        e.g. "use Department, Program, Advisor as keywords" means you should
        read that specific person's actual Department/Program/Advisor off
        the page and put those values in `keywords` for their row, not
        repeat the rule text itself. If the rules don't say anything about
        keywords, leave `keywords` blank for every row.

        If this section contains no matching people, return an empty rows
        array.
      TEXT
    end
    private_class_method :system_message

    def self.dedupe(rows)
      rows.uniq { |row| row[:email].downcase }
    end
    private_class_method :dedupe
  end
end
