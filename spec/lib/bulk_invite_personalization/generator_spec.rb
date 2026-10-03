# frozen_string_literal: true

RSpec.describe BulkInvitePersonalization::Generator do
  fab!(:admin)
  fab!(:invite) { Fabricate(:invite, invited_by: admin, email: "student@iitb.ac.in") }

  let(:invite_link) { invite.link(with_email_token: !Invite.email_code_enabled?) }

  before do
    SiteSetting.bulk_invite_ai_personalization_template = "Come check out our forum. %{invite_link}"
  end

  # The discourse-ai plugin (and its LlmModel/Prompt/Llm classes) is only
  # loaded in this core spec run under LOAD_PLUGINS=1 -- everything that
  # doesn't need a real LLM call is exercised unconditionally below, and the
  # plugin-dependent examples are grouped separately so they can be skipped
  # cleanly when it isn't loaded.
  describe ".personalize" do
    context "when discourse-ai is not available or not enabled" do
      before { SiteSetting.discourse_ai_enabled = false if defined?(DiscourseAi) }

      it "returns nil regardless of whether the plugin is loaded" do
        expect(described_class.personalize(invite)).to eq(nil)
      end
    end

    context "when the feature is disabled" do
      before { SiteSetting.bulk_invite_ai_personalization_enabled = false }

      it "returns nil without needing discourse-ai at all" do
        expect(described_class.personalize(invite)).to eq(nil)
      end
    end

    context "when the invite has skip_personalization set" do
      before do
        invite.update!(skip_personalization: true)
        SiteSetting.bulk_invite_ai_personalization_enabled = true
      end

      it "returns nil even though the feature is otherwise enabled" do
        expect(described_class.personalize(invite)).to eq(nil)
      end
    end

    context "when the base template is blank" do
      before do
        SiteSetting.bulk_invite_ai_personalization_enabled = true
        SiteSetting.bulk_invite_ai_personalization_template = ""
      end

      it "returns nil" do
        expect(described_class.personalize(invite)).to eq(nil)
      end
    end

    context "when personalization is enabled with a template" do
      before { SiteSetting.bulk_invite_ai_personalization_enabled = true }

      if defined?(DiscourseAi)
        fab!(:llm_model, :fake_model)

        before do
          SiteSetting.ai_default_llm_model = llm_model.id
          # resolve_llm re-queries by id rather than reusing this fab!, so
          # stubbing methods directly on llm_model (below) would silently no-op
          # without this -- LlmModel.find_by returns a distinct AR instance.
          allow(LlmModel).to receive(:find_by).and_return(llm_model)
        end

        it "returns nil when no LlmModel can be resolved" do
          SiteSetting.ai_default_llm_model = ""
          llm_model.destroy!

          expect(described_class.personalize(invite)).to eq(nil)
        end

        it "returns the parsed subject and body, with the real link always appended after it, from a compliant, well-formatted LLM response" do
          compliant =
            "SUBJECT: Quick hello from campus\n" \
              "BODY:\n" \
              "A few of us from your college network hang out here, worth a look?"

          result = nil
          DiscourseAi::Completions::Llm.with_prepared_responses([compliant]) do
            result = described_class.personalize(invite)
          end

          expect(result).to eq(
            subject: "Quick hello from campus",
            body:
              "A few of us from your college network hang out here, worth a look?\n\n" \
                "Please use the following invite link to join the forum:\n#{invite_link}",
          )
        end

        it "extracts only the text parts when the LLM returns an Array (e.g. Gemini interactions endpoints mixing text with a Thinking object)" do
          compliant = "SUBJECT: Quick hello\nBODY:\nWorth a look?"
          llm = instance_double(DiscourseAi::Completions::Llm)
          allow(llm_model).to receive(:to_llm).and_return(llm)
          allow(llm).to receive(:generate).and_return(
            [compliant, DiscourseAi::Completions::Thinking.new(message: nil, partial: false)],
          )

          expect(described_class.personalize(invite)).to eq(
            subject: "Quick hello",
            body:
              "Worth a look?\n\nPlease use the following invite link to join the forum:\n#{invite_link}",
          )
        end

        it "strips the real link out of the prompt the LLM sees entirely, even though the template renders it" do
          # The admin's template contains the real link (rendered by
          # render_base_template), but the LLM itself should never see a
          # real, copyable URL to be tempted to echo back, nor any
          # placeholder marker standing in for one -- it doesn't need any
          # link-shaped context to write its note. Seeing the real one
          # would only make a rejected, wasted call more likely, never a
          # bad sent email (ResponseValidator rejects any link-shaped text
          # unconditionally regardless), so there's no reason to show it.
          SiteSetting.bulk_invite_ai_personalization_template = "Join us: %{invite_link}"
          compliant = "SUBJECT: Quick hello\nBODY:\nWorth a look?"
          llm = instance_double(DiscourseAi::Completions::Llm)
          allow(llm_model).to receive(:to_llm).and_return(llm)
          captured_prompt = nil
          allow(llm).to receive(:generate) do |prompt, **|
            captured_prompt = prompt
            compliant
          end

          described_class.personalize(invite)

          expect(captured_prompt.system_message_text).not_to include(invite_link)
          expect(captured_prompt.system_message_text).not_to include("%{invite_link}")
          expect(captured_prompt.system_message_text).to include("Join us:")
        end

        it "requests the lowest thinking effort and the admin-configured token budget, to avoid truncating before the link is written" do
          # Confirmed in production via AiApiAuditLog: 57% of real calls hit
          # finishReason MAX_TOKENS before completing BODY, because Gemini's
          # reasoning step was consuming the budget -- thinking_effort: "none"
          # (this model's lowest supported effort) plus a raised ceiling are
          # both part of the fix, not alternatives to each other. The ceiling
          # is admin-configurable (bulk_invite_ai_personalization_max_tokens)
          # rather than fixed, since the right budget depends on the model
          # and rules in use at a given site.
          SiteSetting.bulk_invite_ai_personalization_max_tokens = 3000
          compliant = "SUBJECT: Quick hello\nBODY:\nWorth a look?"
          llm = instance_double(DiscourseAi::Completions::Llm)
          allow(llm_model).to receive(:to_llm).and_return(llm)
          allow(llm).to receive(:generate).and_return(compliant)

          described_class.personalize(invite)

          expect(llm).to have_received(:generate).with(
            anything,
            hash_including(thinking_effort: "none", max_tokens: 3000),
          )
        end

        it "raises GenerationFailed, rather than returning nil, when the response can't be parsed into subject/body" do
          # With AI personalization on, an admin wants a properly personalized
          # email or nothing sent at all (held back to retry) -- never a
          # silent fallback to the plain template or a stale previous body.
          malformed = "Check this out NOW at https://example.com!"

          expect {
            DiscourseAi::Completions::Llm.with_prepared_responses([malformed]) do
              described_class.personalize(invite)
            end
          }.to raise_error(described_class::GenerationFailed, %r{parseable SUBJECT:/BODY})
        end

        it "does not reject the body for mentioning the recipient's own email domain" do
          # Confirmed in production: an otherwise-compliant body mentioning
          # the recipient's institute by email domain (exactly what the
          # rules tell the model to do when it doesn't know the real
          # institution name) was being rejected as an "unexpected link".
          compliant = "SUBJECT: Hey\nBODY:\nGreat to connect with iitb.ac.in folks, worth a look?"

          result = nil
          DiscourseAi::Completions::Llm.with_prepared_responses([compliant]) do
            result = described_class.personalize(invite)
          end

          expect(result[:body]).to include("Great to connect with iitb.ac.in folks, worth a look?")
        end

        it "raises GenerationFailed, rather than returning nil, when the body fails the anti-spam rules" do
          non_compliant =
            "SUBJECT: Hey\nBODY:\nCheck this out NOW at https://spam.example.com! #{invite_link}"

          expect {
            DiscourseAi::Completions::Llm.with_prepared_responses([non_compliant]) do
              described_class.personalize(invite)
            end
          }.to raise_error(described_class::GenerationFailed, /body failed validation/)
        end

        it "always appends the real join link after the body, even if the model wrote something where a link might go" do
          text = "SUBJECT: Hey\nBODY:\nA few of us hang out here, worth a look?"

          result = :unset
          DiscourseAi::Completions::Llm.with_prepared_responses([text]) do
            result = described_class.personalize(invite)
          end

          expect(result[:subject]).to eq("Hey")
          expect(result[:body]).to include("A few of us hang out here, worth a look?")
          expect(result[:body]).to include(invite_link)
        end

        it "raises GenerationFailed, rather than returning the body with a blank subject, when only the subject fails validation" do
          bad_subject = "SUBJECT: Check this out https://example.com\nBODY:\nWorth a look?"

          expect {
            DiscourseAi::Completions::Llm.with_prepared_responses([bad_subject]) do
              described_class.personalize(invite)
            end
          }.to raise_error(described_class::GenerationFailed, /subject failed validation/)
        end

        it "raises GenerationFailed, rather than appending the link, when the model writes its own link in the body" do
          # The model is told not to write the link itself -- any link-shaped
          # text in the body (even the correct one) means it ignored that,
          # and is rejected rather than trusted or silently stripped.
          wrote_own_link = "SUBJECT: Hey\nBODY:\nWorth a look? #{invite_link}"

          expect {
            DiscourseAi::Completions::Llm.with_prepared_responses([wrote_own_link]) do
              described_class.personalize(invite)
            end
          }.to raise_error(described_class::GenerationFailed, /body failed validation/)
        end

        it "raises GenerationFailed with the underlying error when the LLM call errors" do
          llm = instance_double(DiscourseAi::Completions::Llm)
          allow(llm_model).to receive(:to_llm).and_return(llm)
          allow(llm).to receive(:generate).and_raise(
            DiscourseAi::Completions::Endpoints::Base::CompletionFailed.new(
              '{"error":{"code":"too_many_requests"}}',
            ),
          )

          expect { described_class.personalize(invite) }.to raise_error(
            described_class::GenerationFailed,
            /CompletionFailed.*too_many_requests/,
          )
        end
      else
        it "skips discourse-ai-dependent examples (run with LOAD_PLUGINS=1 to cover them)" do
          skip "discourse-ai plugin not loaded in this spec run"
        end
      end
    end
  end

  describe ".render_base_template" do
    it "substitutes site_title, site_description, and the given link" do
      SiteSetting.bulk_invite_ai_personalization_template =
        "Join %{site_title}: %{invite_link}\n%{site_description}"

      rendered = described_class.send(:render_base_template, "https://example.com/invites/xyz")

      expect(rendered).to eq(
        "Join #{SiteSetting.title}: https://example.com/invites/xyz\n#{SiteSetting.site_description}",
      )
    end

    it "leaves an unrecognized token as literal text instead of raising" do
      SiteSetting.bulk_invite_ai_personalization_template = "Hello %{nonexistent_token}"

      expect(described_class.send(:render_base_template, "https://example.com/invites/xyz")).to eq(
        "Hello %{nonexistent_token}",
      )
    end

    it "returns nil when the template is blank" do
      SiteSetting.bulk_invite_ai_personalization_template = ""

      expect(described_class.send(:render_base_template, "https://example.com/invites/xyz")).to eq(
        nil,
      )
    end
  end

  describe ".parse_response" do
    it "splits a well-formed SUBJECT/BODY response" do
      text = "SUBJECT: Quick hello\nBODY:\nLine one.\nLine two."

      expect(described_class.send(:parse_response, text)).to eq(
        subject: "Quick hello",
        body: "Line one.\nLine two.",
      )
    end

    it "is tolerant of surrounding whitespace and case" do
      text = "  subject:   Quick hello  \n  body:  \n  Body text here.  "

      expect(described_class.send(:parse_response, text)).to eq(
        subject: "Quick hello",
        body: "Body text here.",
      )
    end

    it "returns nil when the format can't be matched" do
      expect(described_class.send(:parse_response, "Just a plain reply with no markers.")).to eq(
        nil,
      )
    end

    it "returns nil when either part is blank" do
      expect(described_class.send(:parse_response, "SUBJECT: \nBODY:\nSome body")).to eq(nil)
      expect(described_class.send(:parse_response, "SUBJECT: Something\nBODY:\n")).to eq(nil)
    end
  end

  describe ".user_message" do
    it "sends only the email domain when no recipient context is given" do
      expect(described_class.send(:user_message, invite)).to eq(
        "Recipient email domain: iitb.ac.in",
      )
    end

    it "appends the recipient name when present" do
      invite.update!(recipient_name: "Priya")

      expect(described_class.send(:user_message, invite)).to eq(
        "Recipient email domain: iitb.ac.in\nRecipient name: Priya",
      )
    end

    it "appends additional context when keywords are present" do
      invite.update!(recipient_keywords: "robotics club, class of 2022")

      expect(described_class.send(:user_message, invite)).to eq(
        "Recipient email domain: iitb.ac.in\nAdditional context: robotics club, class of 2022",
      )
    end

    it "appends both name and keywords when both are present" do
      invite.update!(recipient_name: "Priya", recipient_keywords: "robotics club")

      expect(described_class.send(:user_message, invite)).to eq(
        "Recipient email domain: iitb.ac.in\nRecipient name: Priya\nAdditional context: robotics club",
      )
    end

    it "falls back to description for the email domain on allow_any_email invites" do
      invite.update!(email: nil, description: "student@iitb.ac.in", allow_any_email: true)

      expect(described_class.send(:user_message, invite)).to eq(
        "Recipient email domain: iitb.ac.in",
      )
    end

    it "appends extra_keywords as additional context when the invite has none stored" do
      expect(described_class.send(:user_message, invite, extra_keywords: "math olympiad")).to eq(
        "Recipient email domain: iitb.ac.in\nAdditional context: math olympiad",
      )
    end

    it "combines stored recipient_keywords and extra_keywords" do
      invite.update!(recipient_keywords: "robotics club")

      expect(described_class.send(:user_message, invite, extra_keywords: "math olympiad")).to eq(
        "Recipient email domain: iitb.ac.in\nAdditional context: robotics club, math olympiad",
      )
    end

    it "ignores a blank extra_keywords" do
      invite.update!(recipient_keywords: "robotics club")

      expect(described_class.send(:user_message, invite, extra_keywords: "")).to eq(
        "Recipient email domain: iitb.ac.in\nAdditional context: robotics club",
      )
    end
  end

  describe ".system_message" do
    it "interpolates SiteSetting.bulk_invite_ai_personalization_rules" do
      SiteSetting.bulk_invite_ai_personalization_rules = "- A custom test-only rule."

      message = described_class.send(:system_message, "Come check out our forum.")

      expect(message).to include("- A custom test-only rule.")
      expect(message).to include("Come check out our forum.")
    end

    it "tells the model never to write the link itself, and includes the required SUBJECT/BODY response format" do
      message = described_class.send(:system_message, "Come check out our forum.")

      expect(message).to include("never write the link")
      expect(message).to include("SUBJECT:")
      expect(message).to include("BODY:")
    end

    it "reproduces the original hardcoded rule content via the setting's default value" do
      message = described_class.send(:system_message, "Come check out our forum.")

      expect(message).to include(
        "Total words should be around 100 words, in 2 paragraphs, and fine to have as few as 10-20 words.",
      )
      expect(message).to include("No exclamation points. No ALL CAPS words. No dollar signs.")
      expect(message).to include("never invent or guess a specific name")
    end
  end
end
