# frozen_string_literal: true

RSpec.describe BulkInvitePersonalization::ResponseValidator do
  let(:link) { "https://example.com/invites/abc123" }

  describe ".clean_body" do
    let(:link_line) { "\n\nPlease use the following invite link to join the forum:\n#{link}" }

    it "returns nil for blank input" do
      expect(described_class.clean_body(nil, required_link: link)).to eq(nil)
      expect(described_class.clean_body("", required_link: link)).to eq(nil)
      expect(described_class.clean_body("   ", required_link: link)).to eq(nil)
    end

    it "returns the text unchanged (modulo whitespace) with the required link always appended after it" do
      text =
        "Hey, a few of us from your college network have been chatting here " \
          "about internships and course notes. Thought it might be useful for " \
          "you too. Open to taking a look?"

      expect(described_class.clean_body(text, required_link: link)).to eq("#{text}#{link_line}")
    end

    it "collapses excess whitespace within a single paragraph before appending the link" do
      text = "Hey there.\n  Open   to a quick look?"
      expect(described_class.clean_body(text, required_link: link)).to eq(
        "Hey there. Open to a quick look?#{link_line}",
      )
    end

    it "preserves a blank-line paragraph break, collapsing whitespace only within each paragraph" do
      text = "Hey there,  this is   paragraph one.\n\nAnd this is   paragraph two, worth a look?"
      expect(described_class.clean_body(text, required_link: link)).to eq(
        "Hey there, this is paragraph one.\n\n" \
          "And this is paragraph two, worth a look?#{link_line}",
      )
    end

    it "collapses three or more blank lines between paragraphs down to a single paragraph break" do
      text = "Paragraph one.\n\n\n\nParagraph two, worth a look?"
      expect(described_class.clean_body(text, required_link: link)).to eq(
        "Paragraph one.\n\nParagraph two, worth a look?#{link_line}",
      )
    end

    it "strips HTML tags before appending the link" do
      text = "Hey <b>there</b>, worth a look?"
      expect(described_class.clean_body(text, required_link: link)).to eq(
        "Hey there, worth a look?#{link_line}",
      )
    end

    it "rejects when the model writes the required link itself, rather than leaving it to be appended" do
      # The model is told never to write the link (see Generator#system_message)
      # -- it is always appended separately afterward, so any link-shaped
      # text in the model's own output, even the correct link, is rejected
      # rather than trusted or exempted.
      expect(described_class.clean_body("Hey, worth a look? #{link}", required_link: link)).to eq(
        nil,
      )
    end

    it "rejects a bare domain in the model's text" do
      expect(
        described_class.clean_body(
          "Head to example.com to learn more, interested?",
          required_link: link,
        ),
      ).to eq(nil)
    end

    it "rejects www. text" do
      expect(
        described_class.clean_body(
          "Visit www.example.com sometime, interested?",
          required_link: link,
        ),
      ).to eq(nil)
    end

    it "does not reject a bare mention of the recipient's own email domain" do
      # Confirmed in production: the model correctly followed the rule
      # letting it reference the recipient's institution by email domain
      # when it doesn't know the real name (e.g. "spjimr.org") -- that is
      # prose, not a link, and must not be rejected as one.
      text = "Hope you are doing well at spjimr.org. Worth a look?"
      expect(
        described_class.clean_body(text, required_link: link, recipient_domain: "spjimr.org"),
      ).to eq("#{text}#{link_line}")
    end

    it "still rejects the recipient's own domain if it's written as an actual link" do
      text = "Hope you are doing well, visit www.spjimr.org sometime."
      expect(
        described_class.clean_body(text, required_link: link, recipient_domain: "spjimr.org"),
      ).to eq(nil)
    end

    it "still rejects an unrelated domain even when a recipient_domain is given" do
      text = "Head to example.com to learn more, interested?"
      expect(
        described_class.clean_body(text, required_link: link, recipient_domain: "spjimr.org"),
      ).to eq(nil)
    end

    it "exempts a shortened parent domain the model writes instead of the recipient's literal subdomain" do
      # Confirmed in production: an allow_any_email invite's real address is
      # often on a subdomain (e.g. "student.nitw.ac.in"), and the model
      # naturally writes the shorter, recognizable parent domain instead
      # ("nitw.ac.in") -- rejecting that as an unrelated link/domain was
      # skipping a large share of an otherwise-compliant batch.
      text = "Reaching out to folks at nitw.ac.in, worth a look?"
      expect(
        described_class.clean_body(
          text,
          required_link: link,
          recipient_domain: "student.nitw.ac.in",
        ),
      ).to eq("#{text}#{link_line}")
    end

    it "exempts the recipient's literal subdomain itself, not just the shortened form" do
      text = "Reaching out to folks at student.nitw.ac.in, worth a look?"
      expect(
        described_class.clean_body(
          text,
          required_link: link,
          recipient_domain: "student.nitw.ac.in",
        ),
      ).to eq("#{text}#{link_line}")
    end

    it "still rejects an unrelated domain even when the recipient is on a subdomain" do
      text = "Head to example.com to learn more, interested?"
      expect(
        described_class.clean_body(
          text,
          required_link: link,
          recipient_domain: "student.nitw.ac.in",
        ),
      ).to eq(nil)
    end

    it "still rejects a bare 'www.' with nothing domain-shaped after it" do
      text = "Visit www. sometime, interested?"
      expect(
        described_class.clean_body(
          text,
          required_link: link,
          recipient_domain: "student.nitw.ac.in",
        ),
      ).to eq(nil)
    end

    it "rejects a different/altered link just as readily as the real one" do
      altered = link.sub("abc123", "xyz789")
      expect(described_class.clean_body("Worth a look? #{altered}", required_link: link)).to eq(nil)
    end

    it "rejects text containing markdown formatting" do
      expect(described_class.clean_body("**Join us**, worth a look?", required_link: link)).to eq(
        nil,
      )
      expect(
        described_class.clean_body(
          "[Click here](https://x.test), worth a look?",
          required_link: link,
        ),
      ).to eq(nil)
      expect(described_class.clean_body("# Big news, worth a look?", required_link: link)).to eq(
        nil,
      )
    end

    it "rejects a bullet list that starts partway through the text, not just at the very beginning" do
      # Observed in production: a model appending its own rule-compliance
      # self-check after the real note, formatted as a bullet list. Collapsing
      # whitespace before this check would merge every line into the first,
      # hiding a bullet that doesn't open the whole response.
      text = <<~TEXT
        A few of us from your college network have been chatting here, worth a look?

        * 3-4 sentences max? Exactly 3 sentences.
        * No links, URLs, domains? None.
        * No greeting or sign-off? Checked.
      TEXT
      expect(described_class.clean_body(text, required_link: link)).to eq(nil)
    end

    it "rejects text containing an exclamation point" do
      expect(described_class.clean_body("Join us now! Worth a look?", required_link: link)).to eq(
        nil,
      )
    end

    it "rejects text containing a dollar sign" do
      expect(
        described_class.clean_body("Save $50 today, worth a look?", required_link: link),
      ).to eq(nil)
    end

    it "rejects text containing an ALL CAPS word" do
      expect(
        described_class.clean_body("This is AMAZING, worth a look?", required_link: link),
      ).to eq(nil)
    end

    it "does not reject short acronyms" do
      text = "A few of us from AI club have been chatting here, worth a look?"
      expect(described_class.clean_body(text, required_link: link)).to eq("#{text}#{link_line}")
    end

    it "does not reject allow-listed institute acronyms" do
      text = "A few of us from MNIT and other NIT campuses connect here, worth a look?"
      expect(described_class.clean_body(text, required_link: link)).to eq("#{text}#{link_line}")
    end

    it "still rejects a non-allow-listed ALL CAPS word alongside an allow-listed acronym" do
      text = "This is AMAZING for MNIT folks, worth a look?"
      expect(described_class.clean_body(text, required_link: link)).to eq(nil)
    end

    it "does not reject the natural plural of an allow-listed acronym" do
      # Confirmed in production: the model routinely writes "NITS" (plural)
      # rather than the bare "NIT" acronym -- an otherwise clean, compliant
      # response was being rejected as shouting for that alone.
      text = "A few of us from NITS and other NIT campuses connect here, worth a look?"
      expect(described_class.clean_body(text, required_link: link)).to eq("#{text}#{link_line}")
    end

    it "still rejects a genuinely non-allow-listed ALL CAPS word even as a plural" do
      text = "This is AMAZING for MNIT folks, worth a look?"
      expect(
        described_class.clean_body(text.sub("AMAZING", "AMAZINGS"), required_link: link),
      ).to eq(nil)
    end

    it "reads the acronym allowlist from the site setting, not a fixed list" do
      text = "A few of us from ACME folks connect here, worth a look?"
      expect(described_class.clean_body(text, required_link: link)).to eq(nil)

      SiteSetting.institute_acronyms = "ACME"
      expect(described_class.clean_body(text, required_link: link)).to eq("#{text}#{link_line}")
    end

    it "does not reject the recipient's own institute acronym, even when it's not on the allowlist" do
      # Confirmed in production: MNNIT (mnnit.ac.in) was getting rejected
      # even though the similarly-named but distinct MNIT was allow-listed
      # -- a site serving many institutes will always be one domain behind
      # a hand-maintained allowlist.
      text = "A few of us from MNNIT wanted to reach out, worth a look?"
      expect(
        described_class.clean_body(text, required_link: link, recipient_domain: "mnnit.ac.in"),
      ).to eq("#{text}#{link_line}")
    end

    it "still rejects the same word when it doesn't match the recipient's own domain" do
      text = "A few of us from MNNIT wanted to reach out, worth a look?"
      expect(
        described_class.clean_body(text, required_link: link, recipient_domain: "iitb.ac.in"),
      ).to eq(nil)
    end

    it "tolerates the natural plural of the recipient's own domain acronym too" do
      text = "A few of us from MNNITS wanted to reach out, worth a look?"
      expect(
        described_class.clean_body(text, required_link: link, recipient_domain: "mnnit.ac.in"),
      ).to eq("#{text}#{link_line}")
    end

    it "does not reject an institute acronym embedded anywhere in the recipient's domain, not just its first label" do
      # Confirmed in production: an allow_any_email invite's real address is
      # often on a subdomain where the institute code isn't the leftmost
      # label (e.g. "smail.iitm.ac.in") -- deriving the acronym from only
      # the first label was missing these (IITM, IITD, IITH...) even though
      # NIT/MNIT/IIT were already allow-listed.
      text = "A few of us from IITM wanted to reach out, worth a look?"
      expect(
        described_class.clean_body(text, required_link: link, recipient_domain: "smail.iitm.ac.in"),
      ).to eq("#{text}#{link_line}")
    end

    it "still rejects the same word when it isn't contained anywhere in the recipient's domain" do
      text = "A few of us from IITM wanted to reach out, worth a look?"
      expect(
        described_class.clean_body(
          text,
          required_link: link,
          recipient_domain: "student.nitw.ac.in",
        ),
      ).to eq(nil)
    end

    it "exempts an ALL-CAPS word that appears in the invite's own exempt_keywords" do
      # Confirmed in production: a CSV with recipient_keywords like
      # "WSAI;IDDD" (real lab/program codes, not spam) -- the model follows
      # its own instructions to use that context and writes it back
      # verbatim, which was being rejected every time since those terms
      # could never belong on the site-wide institute_acronyms allowlist.
      text = "Given your work with WSAI, worth a look?"
      expect(
        described_class.clean_body(text, required_link: link, exempt_keywords: "WSAI;IDDD"),
      ).to eq("#{text}#{link_line}")
    end

    it "tolerates the natural plural of an exempt_keywords word too" do
      text = "Given your work with WSAIS, worth a look?"
      expect(
        described_class.clean_body(text, required_link: link, exempt_keywords: "WSAI;IDDD"),
      ).to eq("#{text}#{link_line}")
    end

    it "still rejects an ALL-CAPS word that isn't in exempt_keywords, the domain, or the allowlist" do
      text = "This is AMAZING, worth a look?"
      expect(
        described_class.clean_body(text, required_link: link, exempt_keywords: "WSAI;IDDD"),
      ).to eq(nil)
    end

    it "truncates text over 100 words at the last sentence boundary, then still appends the real link after it" do
      sentence = "This is one short sentence about the community."
      long_text = ([sentence] * 15).join(" ") + " Worth a look?"

      result = described_class.clean_body(long_text, required_link: link)
      body_only = result.sub(link_line, "")

      expect(body_only.split(" ").length).to be <= described_class::MAX_WORDS
      expect(body_only).to match(/[.?]\z/)
      expect(result).to include(link)
    end

    it "rejects when no clean sentence boundary exists under the word limit" do
      long_text = (["word"] * 150).join(" ")
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

    it "does not reject a bare mention of the recipient's own email domain" do
      # Confirmed in production: "quick invite for nitp.ac.in alumni" was
      # rejected even though it's a correct, instructed use of the
      # recipient's domain, not a link.
      text = "quick invite for spjimr.org alumni"
      expect(described_class.clean_subject(text, recipient_domain: "spjimr.org")).to eq(text)
    end

    it "still rejects an unrelated domain even when a recipient_domain is given" do
      expect(
        described_class.clean_subject(
          "Check this out: example.com",
          recipient_domain: "spjimr.org",
        ),
      ).to eq(nil)
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

    it "does not reject the recipient's own institute acronym, even when it's not on the allowlist" do
      expect(
        described_class.clean_subject("Hello from MNNIT", recipient_domain: "mnnit.ac.in"),
      ).to eq("Hello from MNNIT")
    end

    it "still rejects the same word in a subject when it doesn't match the recipient's own domain" do
      expect(
        described_class.clean_subject("Hello from MNNIT", recipient_domain: "iitb.ac.in"),
      ).to eq(nil)
    end

    it "does not reject an institute acronym embedded anywhere in the recipient's domain in a subject too" do
      expect(
        described_class.clean_subject("Hello from IITM", recipient_domain: "smail.iitm.ac.in"),
      ).to eq("Hello from IITM")
    end

    it "exempts an ALL-CAPS word from exempt_keywords in a subject too" do
      expect(described_class.clean_subject("Note about WSAI", exempt_keywords: "WSAI")).to eq(
        "Note about WSAI",
      )
    end

    it "still rejects a subject link when the recipient is on a subdomain but the match is unrelated" do
      expect(
        described_class.clean_subject(
          "Check this out: example.com",
          recipient_domain: "student.nitw.ac.in",
        ),
      ).to eq(nil)
    end

    it "does not reject a shortened parent domain in a subject either" do
      expect(
        described_class.clean_subject(
          "quick invite for nitw.ac.in alumni",
          recipient_domain: "student.nitw.ac.in",
        ),
      ).to eq("quick invite for nitw.ac.in alumni")
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
