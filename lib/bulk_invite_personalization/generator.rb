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
    MAX_TOKENS = 220
    TEMPERATURE = 0.9

    def self.personalize(invite)
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

      llm.generate(
        prompt,
        user: invite.invited_by || Discourse.system_user,
        feature_name: "bulk_invite_personalization",
        max_tokens: MAX_TOKENS,
        temperature: TEMPERATURE,
      )
    end
    private_class_method :call_llm

    def self.system_message(template)
      <<~TEXT
        You are rewriting a short invitation note for one specific recipient,
        working from a base pitch an admin has provided. Follow every rule
        below exactly.

        Output rules (all mandatory):
        - Output strictly plain text. No HTML tags, no Markdown formatting (no
          asterisks, headers, bullet lists, or links in brackets), no tracking
          pixels.
        - Under 75 words total, 3-4 sentences max.
        - Do NOT include any links, URLs, domains, or attachments anywhere in
          your output. A join link will be appended separately by the system
          -- never reference or invent one.
        - Do not write a greeting/salutation or a sign-off/signature -- the
          surrounding email template already supplies those. Output only the
          body note itself.
        - Tone: conversational, peer-to-peer, low-pressure. No marketing
          jargon or buzzwords (e.g. "revolutionary", "boost revenue",
          "guarantee").
        - No exclamation points. No ALL CAPS words. No dollar signs.
        - End with a low-friction, interest-based question (e.g. "Open to
          exploring this?"), not a hard call to action.
        - Vary sentence structure and phrasing each time you are called --
          never reuse the same opening sentence pattern, so automated spam
          filters cannot fingerprint a repeated template.
        - You may reference the recipient's college/institution ONLY using
          the email domain given to you below. If you are not confident of
          the exact institution name from the domain, refer to it generically
          as "your college" or "your institution" -- never invent or guess a
          specific name.

        Base pitch to rework (preserve its core message and call-to-action,
        but rewrite it fully in your own words per the rules above):

        #{template}
      TEXT
    end
    private_class_method :system_message

    def self.user_message(invite)
      "Recipient email domain: #{invite.email.to_s.split("@").last}"
    end
    private_class_method :user_message
  end
end
