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

        before { SiteSetting.ai_default_llm_model = llm_model.id }

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

        it "returns nil when the LLM response violates the anti-spam rules" do
          non_compliant = "Check this out NOW at https://example.com!"

          result = :unset
          DiscourseAi::Completions::Llm.with_prepared_responses([non_compliant]) do
            result = described_class.personalize(invite)
          end

          expect(result).to eq(nil)
        end

        it "returns nil and does not raise when the LLM call errors" do
          llm = instance_double(DiscourseAi::Completions::Llm)
          allow(llm_model).to receive(:to_llm).and_return(llm)
          allow(llm).to receive(:generate).and_raise(StandardError.new("boom"))

          expect(described_class.personalize(invite)).to eq(nil)
        end
      else
        it "skips discourse-ai-dependent examples (run with LOAD_PLUGINS=1 to cover them)" do
          skip "discourse-ai plugin not loaded in this spec run"
        end
      end
    end
  end
end
