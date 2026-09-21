# frozen_string_literal: true

module BulkInvitePersonalization
  # Generates a distinct, anti-spam-styled invite note for one bulk-invite
  # recipient by asking the site's configured AI language model to rework an
  # admin-provided base pitch. Called once per invite, right before send, from
  # Jobs::ProcessBulkInviteEmails -- never from Jobs::BulkInvite, which can be
  # processing thousands of rows in a single job run.
  #
  # Fails safe at every step: any missing prerequisite (plugin disabled,
  # feature off, no template, no LLM configured) or any error from the LLM
  # call itself returns nil rather than raising, so a bulk invite always still
  # sends via the plain, non-personalized template as a fallback.
  module Generator
    # Gemini's "interactions" endpoints spend part of this budget on an
    # internal reasoning step before any visible text is produced -- a small
    # budget lets reasoning consume the whole allowance and truncates the
    # reply mid-sentence, empirically confirmed against the real endpoint.
    MAX_TOKENS = 1200
    TEMPERATURE = 0.9

    def self.personalize(invite)
      return nil if invite.skip_personalization?
      return nil unless enabled?

      template = SiteSetting.bulk_invite_ai_personalization_template
      return nil if template.blank?

      llm = resolve_llm
      return nil if llm.nil?

      response = call_llm(llm, invite, template)
      return nil if response.blank?

      ResponseValidator.clean(response)
    rescue StandardError => e
      Rails.logger.warn(
        "[BulkInvitePersonalization] failed to personalize invite #{invite.id}: #{e.message}",
      )
      nil
    end

    def self.enabled?
      defined?(DiscourseAi) && SiteSetting.discourse_ai_enabled &&
        SiteSetting.bulk_invite_ai_personalization_enabled
    end
    private_class_method :enabled?

    def self.resolve_llm
      model_id = SiteSetting.ai_default_llm_model
      model = model_id.present? ? LlmModel.find_by(id: model_id) : LlmModel.last
      model&.to_llm
    end
    private_class_method :resolve_llm

    def self.call_llm(llm, invite, template)
      prompt =
        DiscourseAi::Completions::Prompt.new(
          system_message(template),
          messages: [{ type: :user, content: user_message(invite) }],
        )

      response =
        llm.generate(
          prompt,
          user: invite.invited_by || Discourse.system_user,
          feature_name: "bulk_invite_personalization",
          max_tokens: MAX_TOKENS,
          temperature: TEMPERATURE,
        )

      extract_text(response)
    end
    private_class_method :call_llm

    # Some endpoints (e.g. Gemini's "interactions" providers, when reasoning
    # is enabled) return an Array mixing response text with non-text objects
    # like DiscourseAi::Completions::Thinking, rather than a plain String.
    # Passing that array straight to ResponseValidator would sanitize its
    # #inspect representation instead of the actual reply text.
    def self.extract_text(response)
      case response
      when String
        response
      when Array
        response.select { |part| part.is_a?(String) }.join(" ").presence
      end
    end
    private_class_method :extract_text

    def self.system_message(template)
      <<~TEXT
        You are rewriting a short invitation note for one specific recipient,
        working from a base pitch an admin has provided. Follow every rule
        below exactly.

        #{SiteSetting.bulk_invite_ai_personalization_rules}

        Base pitch to rework (preserve its core message and call-to-action,
        but rewrite it fully in your own words per the rules above):

        #{template}
      TEXT
    end
    private_class_method :system_message

    def self.user_message(invite)
      lines = ["Recipient email domain: #{invite.email.to_s.split("@").last}"]
      lines << "Recipient name: #{invite.recipient_name}" if invite.recipient_name.present?
      if invite.recipient_keywords.present?
        lines << "Additional context: #{invite.recipient_keywords}"
      end
      lines.join("\n")
    end
    private_class_method :user_message
  end
end
