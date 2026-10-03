# frozen_string_literal: true

RSpec.describe BulkInvitePersonalization::ResponseValidator do
  let(:link) { "https://example.com/invites/abc123" }

  describe ".clean_body" do
    it "returns nil for blank input" do
      expect(described_class.clean_body(nil, required_link: link)).to eq(nil)
      expect(described_class.clean_body("", required_link: link)).to eq(nil)
      expect(described_class.clean_body("   ", required_link: link)).to eq(nil)
    end

    it "returns a clean, compliant email unchanged (modulo whitespace), including the link" do
      text =
        "Hey, a few of us from your college network have been chatting here " \
          "about internships and course notes. Thought it might be useful for " \
          "you too. Open to taking a look? #{link}"

      expect(described_class.clean_body(text, required_link: link)).to eq(text)
    end

    it "collapses excess whitespace" do
      text = "Hey there.\n\n  Open   to a quick look? #{link}"
      expect(described_class.clean_body(text, required_link: link)).to eq(
        "Hey there. Open to a quick look? #{link}",
      )
    end

    it "strips HTML tags" do
      text = "Hey <b>there</b>, worth a look? #{link}"
      expect(described_class.clean_body(text, required_link: link)).to eq(
        "Hey there, worth a look? #{link}",
      )
    end

    it "exempts the required link itself from the URL check" do
      text = "Hey, worth a look? #{link}"
      expect(described_class.clean_body(text, required_link: link)).to eq(text)
    end

    it "rejects an extra, unexpected link alongside the required one" do
      text = "Check this out #{link} and also https://spam.example.com, interested?"
      expect(described_class.clean_body(text, required_link: link)).to eq(nil)
    end

    it "rejects a bare domain that isn't the required link" do
      expect(
        described_class.clean_body(
          "Head to example.com to learn more, interested? #{link}",
          required_link: link,
        ),
      ).to eq(nil)
    end

    it "rejects www. that isn't the required link" do
      expect(
        described_class.clean_body(
          "Visit www.example.com sometime, interested? #{link}",
          required_link: link,
        ),
      ).to eq(nil)
    end

    it "rejects when the required link is missing entirely" do
      expect(
        described_class.clean_body("A few of us hang out here, worth a look?", required_link: link),
      ).to eq(nil)
    end

    it "rejects when the required link is altered rather than verbatim" do
      altered = link.sub("abc123", "xyz789")
      expect(described_class.clean_body("Worth a look? #{altered}", required_link: link)).to eq(nil)
    end

    it "rejects when truncation to the word limit would cut the link off" do
      sentence = "This is one short sentence about the community."
      # The link sits past the 75-word cutoff, so truncating must not
      # silently keep text that no longer contains it.
      long_text = ([sentence] * 20).join(" ") + " Worth a look? #{link}"

      expect(described_class.clean_body(long_text, required_link: link)).to eq(nil)
    end

    it "rejects text containing markdown formatting" do
      expect(
        described_class.clean_body("**Join us**, worth a look? #{link}", required_link: link),
      ).to eq(nil)
      expect(
        described_class.clean_body(
          "[Click here](https://x.test), worth a look? #{link}",
          required_link: link,
        ),
      ).to eq(nil)
      expect(
        described_class.clean_body("# Big news, worth a look? #{link}", required_link: link),
      ).to eq(nil)
    end

    it "rejects a bullet list that starts partway through the text, not just at the very beginning" do
      # Observed in production: a model appending its own rule-compliance
      # self-check after the real note, formatted as a bullet list. Collapsing
      # whitespace before this check would merge every line into the first,
      # hiding a bullet that doesn't open the whole response.
      text = <<~TEXT
        A few of us from your college network have been chatting here, worth a look? #{link}

        * 3-4 sentences max? Exactly 3 sentences.
        * No links, URLs, domains? None.
        * No greeting or sign-off? Checked.
      TEXT
      expect(described_class.clean_body(text, required_link: link)).to eq(nil)
    end

    it "rejects text containing an exclamation point" do
      expect(
        described_class.clean_body("Join us now! Worth a look? #{link}", required_link: link),
      ).to eq(nil)
    end

    it "rejects text containing a dollar sign" do
      expect(
        described_class.clean_body("Save $50 today, worth a look? #{link}", required_link: link),
      ).to eq(nil)
    end

    it "rejects text containing an ALL CAPS word" do
      expect(
        described_class.clean_body("This is AMAZING, worth a look? #{link}", required_link: link),
      ).to eq(nil)
    end

    it "does not reject short acronyms" do
      text = "A few of us from AI club have been chatting here, worth a look? #{link}"
      expect(described_class.clean_body(text, required_link: link)).to eq(text)
    end

    it "does not reject allow-listed institute acronyms" do
      text = "A few of us from MNIT and other NIT campuses connect here, worth a look? #{link}"
      expect(described_class.clean_body(text, required_link: link)).to eq(text)
    end

    it "still rejects a non-allow-listed ALL CAPS word alongside an allow-listed acronym" do
      text = "This is AMAZING for MNIT folks, worth a look? #{link}"
      expect(described_class.clean_body(text, required_link: link)).to eq(nil)
    end

    it "does not reject the natural plural of an allow-listed acronym" do
      # Confirmed in production: the model routinely writes "NITS" (plural)
      # rather than the bare "NIT" acronym -- an otherwise clean, compliant
      # response was being rejected as shouting for that alone.
      text = "A few of us from NITS and other NIT campuses connect here, worth a look? #{link}"
      expect(described_class.clean_body(text, required_link: link)).to eq(text)
    end

    it "still rejects a genuinely non-allow-listed ALL CAPS word even as a plural" do
      text = "This is AMAZING for MNIT folks, worth a look? #{link}"
      expect(
        described_class.clean_body(text.sub("AMAZING", "AMAZINGS"), required_link: link),
      ).to eq(nil)
    end

    it "reads the acronym allowlist from the site setting, not a fixed list" do
      text = "A few of us from ACME folks connect here, worth a look? #{link}"
      expect(described_class.clean_body(text, required_link: link)).to eq(nil)

      SiteSetting.institute_acronyms = "ACME"
      expect(described_class.clean_body(text, required_link: link)).to eq(text)
    end

    it "truncates text over 75 words at the last sentence boundary, keeping the link" do
      sentence = "This is one short sentence about the community."
      long_text = "#{link} " + ([sentence] * 10).join(" ") + " Worth a look?"

      result = described_class.clean_body(long_text, required_link: link)

      expect(result).to be_present
      expect(result.split(" ").length).to be <= described_class::MAX_WORDS
      expect(result).to match(/[.?]\z/)
      expect(result).to include(link)
    end

    it "rejects when no clean sentence boundary exists under the word limit" do
      long_text = "#{link} " + (["word"] * 100).join(" ")
      expect(described_class.clean_body(long_text, required_link: link)).to eq(nil)
    end
  end

  describe ".clean_subject" do
    it "returns nil for blank input" do
      expect(described_class.clean_subject(nil)).to eq(nil)
      expect(described_class.clean_subject("")).to eq(nil)
      expect(described_class.clean_subject("   ")).to eq(nil)
    end

    it "returns a clean, compliant subject unchanged (modulo whitespace)" do
      expect(described_class.clean_subject("Quick hello from campus")).to eq(
        "Quick hello from campus",
      )
    end

    it "collapses excess whitespace" do
      expect(described_class.clean_subject("Quick   hello\nfrom campus")).to eq(
        "Quick hello from campus",
      )
    end

    it "strips HTML tags" do
      expect(described_class.clean_subject("Quick <b>hello</b>")).to eq("Quick hello")
    end

    it "rejects a subject containing a link" do
      expect(described_class.clean_subject("Check this out: https://example.com")).to eq(nil)
    end

    it "rejects markdown formatting" do
      expect(described_class.clean_subject("**Big news**")).to eq(nil)
    end

    it "rejects an exclamation point" do
      expect(described_class.clean_subject("Join us now!")).to eq(nil)
    end

    it "rejects a dollar sign" do
      expect(described_class.clean_subject("Save $50 today")).to eq(nil)
    end

    it "rejects a non-allow-listed ALL CAPS word" do
      expect(described_class.clean_subject("This is AMAZING")).to eq(nil)
    end

    it "does not reject an allow-listed institute acronym" do
      expect(described_class.clean_subject("Hello from MNIT")).to eq("Hello from MNIT")
    end

    it "rejects a subject over the max word count" do
      long_subject = (["word"] * (described_class::MAX_SUBJECT_WORDS + 1)).join(" ")
      expect(described_class.clean_subject(long_subject)).to eq(nil)
    end

    it "allows a subject right at the max word count" do
      subject_at_limit = (["word"] * described_class::MAX_SUBJECT_WORDS).join(" ")
      expect(described_class.clean_subject(subject_at_limit)).to eq(subject_at_limit)
    end
  end
end
