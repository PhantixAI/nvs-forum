# frozen_string_literal: true

RSpec.describe UrlExtractionRequest do
  fab!(:admin)

  describe "validations" do
    it "requires url and rules" do
      request = UrlExtractionRequest.new(created_by: admin)

      expect(request).not_to be_valid
      expect(request.errors[:url]).to be_present
      expect(request.errors[:rules]).to be_present
    end

    it "is valid with a url, rules, and created_by" do
      request =
        UrlExtractionRequest.new(created_by: admin, url: "https://example.edu", rules: "rules")

      expect(request).to be_valid
    end

    it "does not require rules for a draft" do
      request =
        UrlExtractionRequest.new(
          created_by: admin,
          url: "https://example.edu",
          rules: "",
          status: UrlExtractionRequest.statuses[:draft],
        )

      expect(request).to be_valid
    end

    it "still requires rules once a draft is no longer at :draft status" do
      request =
        UrlExtractionRequest.new(
          created_by: admin,
          url: "https://example.edu",
          rules: "",
          status: UrlExtractionRequest.statuses[:queued],
        )

      expect(request).not_to be_valid
      expect(request.errors[:rules]).to be_present
    end
  end

  describe ".statuses" do
    it "maps the expected symbols to their persisted integer values" do
      expect(UrlExtractionRequest.statuses[:queued]).to eq(0)
      expect(UrlExtractionRequest.statuses[:processing]).to eq(1)
      expect(UrlExtractionRequest.statuses[:ready]).to eq(2)
      expect(UrlExtractionRequest.statuses[:failed]).to eq(3)
      expect(UrlExtractionRequest.statuses[:closed]).to eq(4)
      expect(UrlExtractionRequest.statuses[:draft]).to eq(5)
    end
  end

  describe "#broadcast_progress!" do
    it "publishes the serialized request to the creator's progress channel" do
      request = Fabricate(:url_extraction_request, created_by: admin)

      messages =
        MessageBus.track_publish(UrlExtractionRequest::PROGRESS_CHANNEL) do
          request.broadcast_progress!
        end

      expect(messages.map(&:user_ids)).to eq([[admin.id]])
      expect(messages.first.data[:request][:id]).to eq(request.id)
    end
  end

  describe ".remove_old" do
    it "removes requests older than the retention window, leaving newer ones alone" do
      old_request = Fabricate(:url_extraction_request, created_by: admin, created_at: 3.days.ago)
      recent_request = Fabricate(:url_extraction_request, created_by: admin, created_at: 1.hour.ago)

      expect { UrlExtractionRequest.remove_old }.to change { UrlExtractionRequest.count }.by(-1)

      expect(UrlExtractionRequest.exists?(id: old_request.id)).to eq(false)
      expect(UrlExtractionRequest.exists?(id: recent_request.id)).to eq(true)
    end

    it "leaves old drafts alone -- they're deliberately long-lived and have no csv_text to age out" do
      old_draft =
        Fabricate(
          :url_extraction_request,
          created_by: admin,
          rules: "",
          status: UrlExtractionRequest.statuses[:draft],
          created_at: 3.days.ago,
        )

      expect { UrlExtractionRequest.remove_old }.not_to change { UrlExtractionRequest.count }
      expect(UrlExtractionRequest.exists?(id: old_draft.id)).to eq(true)
    end
  end
end
