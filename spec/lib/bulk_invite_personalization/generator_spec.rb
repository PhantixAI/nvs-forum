# frozen_string_literal: true

RSpec.describe BulkInvitePersonalization::Generator do
  fab!(:admin)
  fab!(:invite) { Fabricate(:invite, invited_by: admin, email: "student@iitb.ac.in") }

  before { SiteSetting.bulk_invite_ai_personalization_template = "Come check out our forum." }

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

        it "returns the sanitized text from a compliant LLM response" do
          compliant = "A few of us from your college network hang out here. Worth a look?"

          result = nil
          DiscourseAi::Completions::Llm.with_prepared_responses([compliant]) do
            result = described_class.personalize(invite)
          end

          expect(result).to eq(compliant)
        end

        it "extracts only the text parts when the LLM returns an Array (e.g. Gemini interactions endpoints mixing text with a Thinking object)" do
          compliant = "A few of us from your college network hang out here. Worth a look?"
          llm = instance_double(DiscourseAi::Completions::Llm)
          allow(llm_model).to receive(:to_llm).and_return(llm)
          allow(llm).to receive(:generate).and_return(
            [compliant, DiscourseAi::Completions::Thinking.new(message: nil, partial: false)],
          )

          expect(described_class.personalize(invite)).to eq(compliant)
        end

        it "returns nil when the LLM response violates the anti-spam rules" do
          non_compliant = "Check this out NOW at https://example.com!"

          result = :unset
          DiscourseAi::Completions::Llm.with_prepared_responses([non_compliant]) do
            result = described_class.personalize(invite)
          end

          expect(result).to eq(nil)
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
  end

  describe ".system_message" do
    it "interpolates SiteSetting.bulk_invite_ai_personalization_rules" do
      SiteSetting.bulk_invite_ai_personalization_rules = "- A custom test-only rule."

      message = described_class.send(:system_message, "Come check out our forum.")

      expect(message).to include("- A custom test-only rule.")
      expect(message).to include("Come check out our forum.")
    end

    it "reproduces the original hardcoded rule content via the setting's default value" do
      message = described_class.send(:system_message, "Come check out our forum.")

      expect(message).to include("Under 75 words total, 3-4 sentences max.")
      expect(message).to include("No exclamation points. No ALL CAPS words. No dollar signs.")
      expect(message).to include("never invent or guess a specific name")
    end
  end
end
