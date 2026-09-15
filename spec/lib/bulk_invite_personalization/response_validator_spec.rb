# frozen_string_literal: true

RSpec.describe BulkInvitePersonalization::ResponseValidator do
  describe ".clean" do
    it "returns nil for blank input" do
      expect(described_class.clean(nil)).to eq(nil)
      expect(described_class.clean("")).to eq(nil)
      expect(described_class.clean("   ")).to eq(nil)
    end

    it "returns a clean, compliant note unchanged (modulo whitespace)" do
      text =
        "Hey, a few of us from your college network have been chatting here " \
          "about internships and course notes. Thought it might be useful for " \
          "you too. Open to taking a look?"

      expect(described_class.clean(text)).to eq(text)
    end

    it "collapses excess whitespace" do
      text = "Hey there.\n\n  Open   to a quick look?"
      expect(described_class.clean(text)).to eq("Hey there. Open to a quick look?")
    end

    it "strips HTML tags" do
      text = "Hey <b>there</b>, worth a look?"
      expect(described_class.clean(text)).to eq("Hey there, worth a look?")
    end

    it "rejects text containing a URL" do
      expect(described_class.clean("Check this out https://example.com, interested?")).to eq(nil)
    end

    it "rejects text containing a bare domain" do
      expect(described_class.clean("Head to example.com to learn more, interested?")).to eq(nil)
    end

    it "rejects text containing www." do
      expect(described_class.clean("Visit www.example.com sometime, interested?")).to eq(nil)
    end

    it "rejects text containing markdown formatting" do
      expect(described_class.clean("**Join us**, worth a look?")).to eq(nil)
      expect(described_class.clean("[Click here](https://x.test), worth a look?")).to eq(nil)
      expect(described_class.clean("# Big news, worth a look?")).to eq(nil)
    end

    it "rejects text containing an exclamation point" do
      expect(described_class.clean("Join us now! Worth a look?")).to eq(nil)
    end

    it "rejects text containing a dollar sign" do
      expect(described_class.clean("Save $50 today, worth a look?")).to eq(nil)
    end

    it "rejects text containing an ALL CAPS word" do
      expect(described_class.clean("This is AMAZING, worth a look?")).to eq(nil)
    end

    it "does not reject short acronyms" do
      text = "A few of us from AI club have been chatting here, worth a look?"
      expect(described_class.clean(text)).to eq(text)
    end

    it "truncates text over 75 words at the last sentence boundary" do
      sentence = "This is one short sentence about the community."
      long_text = ([sentence] * 10).join(" ") + " Worth a look?"

      result = described_class.clean(long_text)

      expect(result).to be_present
      expect(result.split(" ").length).to be <= described_class::MAX_WORDS
      expect(result).to match(/[.?]\z/)
    end

    it "rejects when no clean sentence boundary exists under the word limit" do
      long_text = (["word"] * 100).join(" ")
      expect(described_class.clean(long_text)).to eq(nil)
    end
  end
end
