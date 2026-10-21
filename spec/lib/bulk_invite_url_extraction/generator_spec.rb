# frozen_string_literal: true

RSpec.describe BulkInviteUrlExtraction::Generator do
  describe "TABLE_SEPARATOR_PATTERN" do
    it "matches typical markdown table separator rows" do
      expect(described_class::TABLE_SEPARATOR_PATTERN).to match("| --- | --- |\n")
      expect(described_class::TABLE_SEPARATOR_PATTERN).to match("|---|---|\n")
      expect(described_class::TABLE_SEPARATOR_PATTERN).to match("| :--- | ---: |\n")
    end

    it "does not match an ordinary table data row" do
      expect(described_class::TABLE_SEPARATOR_PATTERN).not_to match(
        "| Priya | priya@iitb.ac.in |\n",
      )
    end
  end

  describe ".chunk_by_line" do
    def chunk(text, budget)
      described_class.send(:chunk_by_line, text, budget)
    end

    it "returns an empty array for blank text" do
      expect(chunk("", 1000)).to eq([])
    end

    it "returns a single chunk when the text fits within the budget" do
      text = "line one\nline two\nline three\n"

      expect(chunk(text, 1000)).to eq([text])
    end

    it "splits into multiple chunks once the budget is exceeded, without losing, duplicating, or reordering any line" do
      lines = (1..50).map { |i| "line #{i}" }
      text = lines.join("\n") + "\n"

      chunks = chunk(text, 100)

      expect(chunks.size).to be > 1
      expect(chunks.join).to eq(text)
    end

    it "repeats a markdown table's header and separator row at the top of a later chunk that starts mid-table" do
      header = "| Name | Email |\n"
      separator = "| --- | --- |\n"
      rows = (1..50).map { |i| "| Student #{i} | student#{i}@example.edu |\n" }.join
      text = header + separator + rows

      chunks = chunk(text, 150)

      expect(chunks.size).to be > 1
      chunks[1..].each { |later_chunk| expect(later_chunk).to start_with(header + separator) }
      # Reconstructing from the original lines (stripping the repeated header
      # out of every chunk after the first) must reproduce the source text --
      # the header repetition is additive context for the model, not a
      # substitute for any real row.
      rebuilt = chunks.first + chunks[1..].map { |c| c.delete_prefix(header + separator) }.join
      expect(rebuilt).to eq(text)
    end

    it "does not repeat a table header into a chunk that starts after the table has ended" do
      header = "| Name | Email |\n"
      separator = "| --- | --- |\n"
      rows = (1..5).map { |i| "| Student #{i} | student#{i}@example.edu |\n" }.join
      trailer = ("Some unrelated closing paragraph text. " * 50) + "\n"
      text = header + separator + rows + trailer

      chunks = chunk(text, 80)

      expect(chunks.last).not_to start_with(header)
    end
  end

  describe ".dedupe" do
    it "keeps the first occurrence and drops a case-insensitive duplicate email" do
      rows = [
        { email: "Priya@iitb.ac.in", name: "Priya" },
        { email: "priya@IITB.ac.in", name: "Priya R" },
      ]

      expect(described_class.send(:dedupe, rows)).to eq(
        [{ email: "Priya@iitb.ac.in", name: "Priya" }],
      )
    end
  end

  describe ".system_message" do
    it "includes the admin-provided extraction rules" do
      message = described_class.send(:system_message, "Construct emails as RollNo@example.edu")

      expect(message).to include("Construct emails as RollNo@example.edu")
    end
  end

  describe ".extract" do
    context "when discourse-ai is not available or not enabled" do
      before { SiteSetting.discourse_ai_enabled = false if defined?(DiscourseAi) }

      it "raises ExtractionFailed regardless of whether the plugin is loaded" do
        expect {
          described_class.extract(url: "https://example.com", rules: "rules")
        }.to raise_error(described_class::ExtractionFailed, /not enabled/)
      end
    end

    context "when the feature is disabled" do
      before { SiteSetting.bulk_invite_url_extraction_enabled = false }

      it "raises ExtractionFailed without needing discourse-ai at all" do
        expect {
          described_class.extract(url: "https://example.com", rules: "rules")
        }.to raise_error(described_class::ExtractionFailed, /not enabled/)
      end
    end

    context "when the feature is enabled" do
      before { SiteSetting.bulk_invite_url_extraction_enabled = true }

      # discourse-ai (and its LlmModel/Prompt/Llm classes) is only loaded in
      # this core spec run under LOAD_PLUGINS=1 -- see
      # spec/lib/bulk_invite_personalization/generator_spec.rb for the same
      # pattern.
      if defined?(DiscourseAi)
        fab!(:llm_model, :fake_model)

        before do
          SiteSetting.discourse_ai_enabled = true
          SiteSetting.ai_default_llm_model = llm_model.id
          allow(LlmModel).to receive(:find_by).and_return(llm_model)
        end

        it "raises ExtractionFailed when no LlmModel can be resolved" do
          SiteSetting.ai_default_llm_model = ""
          llm_model.destroy!

          expect {
            described_class.extract(url: "https://example.com", rules: "rules")
          }.to raise_error(described_class::ExtractionFailed, /No AI language model/)
        end

        it "raises ExtractionFailed when the page can't be fetched" do
          allow(DiscourseAi::Rag::WebPageFetcher).to receive(:fetch).and_raise(
            DiscourseAi::Rag::WebPageFetcher::FetchError.new("The page returned HTTP 404"),
          )

          expect {
            described_class.extract(url: "https://example.com", rules: "rules")
          }.to raise_error(described_class::ExtractionFailed, /Could not fetch the page/)
        end

        it "raises ExtractionFailed when the fetched page has no readable text" do
          allow(DiscourseAi::Rag::WebPageFetcher).to receive(:fetch).and_return(text: "")

          expect {
            described_class.extract(url: "https://example.com", rules: "rules")
          }.to raise_error(described_class::ExtractionFailed, /did not contain any readable text/)
        end

        it "returns the extracted rows, deduped by email, from a compliant response" do
          allow(DiscourseAi::Rag::WebPageFetcher).to receive(:fetch).and_return(
            text: "| Name | Email |\n| --- | --- |\n| Priya | priya@iitb.ac.in |\n",
          )
          canned = {
            rows: [
              { email: "priya@iitb.ac.in", name: "Priya", keywords: "" },
              { email: "PRIYA@iitb.ac.in", name: "Priya", keywords: "" },
            ],
          }.to_json

          result = nil
          DiscourseAi::Completions::Llm.with_prepared_responses([canned]) do
            result = described_class.extract(url: "https://example.com", rules: "rules")
          end

          expect(result.rows).to eq([{ email: "priya@iitb.ac.in", name: "Priya", keywords: "" }])
          expect(result.warnings).to eq([])
        end

        it "returns each row's own extracted keywords, not the admin's rules text" do
          allow(DiscourseAi::Rag::WebPageFetcher).to receive(:fetch).and_return(
            text:
              "| Name | Email | Dept |\n| --- | --- | --- |\n| Priya | priya@iitb.ac.in | Physics |\n",
          )
          canned = {
            rows: [{ email: "priya@iitb.ac.in", name: "Priya", keywords: "Physics" }],
          }.to_json

          result = nil
          DiscourseAi::Completions::Llm.with_prepared_responses([canned]) do
            result =
              described_class.extract(url: "https://example.com", rules: "use Dept as keywords")
          end

          expect(result.rows).to eq(
            [{ email: "priya@iitb.ac.in", name: "Priya", keywords: "Physics" }],
          )
        end

        it "drops a row with a blank email" do
          allow(DiscourseAi::Rag::WebPageFetcher).to receive(:fetch).and_return(text: "some text")
          canned = {
            rows: [
              { email: "", name: "No Email", keywords: "" },
              { email: "ok@example.edu", name: "Ok", keywords: "" },
            ],
          }.to_json

          result = nil
          DiscourseAi::Completions::Llm.with_prepared_responses([canned]) do
            result = described_class.extract(url: "https://example.com", rules: "rules")
          end

          expect(result.rows).to eq([{ email: "ok@example.edu", name: "Ok", keywords: "" }])
        end

        it "salvages complete rows from a chunk whose structured-output JSON got cut off mid-array (e.g. by max_tokens) instead of losing the whole chunk" do
          schema_properties = described_class::ROW_SCHEMA[:json_schema][:schema][:properties]
          truncated = DiscourseAi::Completions::StructuredOutput.new(schema_properties)
          truncated << '{"rows":[{"email":"first@example.edu","name":"First","keywords":""},{"email":"second@ex'
          truncated.finish

          llm = Object.new
          llm.define_singleton_method(:generate) { |*_args, **_kwargs, &blk| blk.call(truncated) }

          rows = described_class.send(:extract_chunk, llm, "chunk text", "rules")

          expect(rows).to include({ email: "first@example.edu", name: "First", keywords: "" })
        end

        it "merges rows across multiple chunks, recording a warning for a chunk whose extraction call fails rather than failing the whole run" do
          long_text = (1..400).map { |i| "Entry #{i}: #{"filler " * 5}" }.join("\n")
          allow(DiscourseAi::Rag::WebPageFetcher).to receive(:fetch).and_return(text: long_text)
          chunk_count =
            described_class.send(:chunk_by_line, long_text, described_class::CHUNK_CHAR_BUDGET).size
          expect(chunk_count).to be >= 2

          first_chunk_response = {
            rows: [{ email: "first@example.edu", name: "First", keywords: "" }],
          }.to_json
          responses =
            [first_chunk_response] + Array.new(chunk_count - 1) { StandardError.new("boom") }

          result = nil
          DiscourseAi::Completions::Llm.with_prepared_responses(responses) do
            result = described_class.extract(url: "https://example.com", rules: "rules")
          end

          expect(result.rows).to eq([{ email: "first@example.edu", name: "First", keywords: "" }])
          expect(result.warnings.size).to eq(chunk_count - 1)
        end

        it "raises ExtractionFailed when every chunk's extraction call fails" do
          allow(DiscourseAi::Rag::WebPageFetcher).to receive(:fetch).and_return(text: "some text")

          expect {
            DiscourseAi::Completions::Llm.with_prepared_responses([StandardError.new("boom")]) do
              described_class.extract(url: "https://example.com", rules: "rules")
            end
          }.to raise_error(described_class::ExtractionFailed, /No rows could be extracted/)
        end
      else
        it "skips discourse-ai-dependent examples (run with LOAD_PLUGINS=1 to cover them)" do
          skip "discourse-ai plugin not loaded in this spec run"
        end
      end
    end
  end
end
