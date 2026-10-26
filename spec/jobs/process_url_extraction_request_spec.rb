# frozen_string_literal: true

RSpec.describe Jobs::ProcessUrlExtractionRequest do
  fab!(:admin)
  fab!(:request) { Fabricate(:url_extraction_request, created_by: admin) }

  describe "#execute" do
    it "extracts rows, builds the CSV, and marks the request ready" do
      BulkInviteUrlExtraction::Generator.stubs(:extract).returns(
        BulkInviteUrlExtraction::Generator::Result.new(
          rows: [{ email: "priya@iitb.ac.in", name: "Priya", keywords: "physics" }],
          warnings: ["Part 2 of 2 of the page could not be processed."],
        ),
      )

      messages =
        MessageBus.track_publish(described_class::CHANNEL) do
          described_class.new.execute(request_id: request.id)
        end

      request.reload
      expect(request.status).to eq(UrlExtractionRequest.statuses[:ready])
      expect(request.csv_text).to eq(
        "email,name,groups,topic_id,locale,keywords\npriya@iitb.ac.in,Priya,,,en,physics",
      )
      expect(request.warnings).to eq(["Part 2 of 2 of the page could not be processed."])
      expect(request.rows_count).to eq(1)

      expect(messages.map(&:user_ids)).to eq([[admin.id]])
      expect(messages.first.data[:request][:id]).to eq(request.id)
      expect(messages.first.data[:request][:status]).to eq(:ready)
    end

    it "marks the request failed with the extraction error when it can't extract anything" do
      BulkInviteUrlExtraction::Generator.stubs(:extract).raises(
        BulkInviteUrlExtraction::Generator::ExtractionFailed.new(
          "Could not fetch the page: timed out",
        ),
      )

      described_class.new.execute(request_id: request.id)

      request.reload
      expect(request.status).to eq(UrlExtractionRequest.statuses[:failed])
      expect(request.error_message).to eq("Could not fetch the page: timed out")
    end

    it "marks the request failed with a generic message on an unexpected error" do
      BulkInviteUrlExtraction::Generator.stubs(:extract).raises(StandardError.new("boom"))

      described_class.new.execute(request_id: request.id)

      request.reload
      expect(request.status).to eq(UrlExtractionRequest.statuses[:failed])
      expect(request.error_message).to eq("Something went wrong while extracting this page.")
    end

    it "does nothing for a request id that no longer exists" do
      request.destroy!

      expect { described_class.new.execute(request_id: request.id) }.not_to raise_error
    end
  end
end
