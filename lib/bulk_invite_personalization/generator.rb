# frozen_string_literal: true

module BulkInvitePersonalization
  # Generates a distinct, anti-spam-styled invite email for one bulk-invite
  # recipient by asking the site's configured AI language model to rework an
  # admin-provided base email. Called once per invite, right before send, from
  # Jobs::ProcessBulkInviteEmails -- never from Jobs::BulkInvite, which can be
  # processing thousands of rows in a single job run.
  #
  # bulk_invite_ai_personalization_template is rendered with real values
  # (site title/description, and the invite's own real join link) before
  # the LLM is involved at all -- but the real link is then stripped back
  # out, with nothing in its place, before that rendered text reaches the
  # prompt, so the model never sees a real, copyable URL to echo back.
  # ResponseValidator always appends the real link afterward itself,
  # verbatim, on its own line: reliably getting an LLM to reproduce a URL
  # with specific formatting (and no typos) across every call is not
  # something worth depending on, so it isn't shown one to reproduce in
  # the first place, not even as a placeholder marker.
  #
  # A missing prerequisite (plugin disabled, feature off, no template, no LLM
  # configured) returns nil -- personalization doesn't apply here at all, so
  # the invite sends with the plain template as always. Once an LLM call is
  # actually attempted, though, every failure past that point -- a blank or
  # unparseable response, a subject or body the validator rejects, or an
  # error from the provider itself -- raises GenerationFailed instead of
  # falling back. With AI personalization turned on, an admin wants either a
  # properly personalized email or nothing sent at all to retry later, never
  # a silently-degraded one (a generic subject, a generic body, or worse, a
  # stale body left over from a previous attempt) going out in its place.
  # The caller is expected to hold the invite back (mark it :skipped) rather
  # than send on this exception -- see Jobs::ProcessBulkInviteEmails,
  # Jobs::ResendInvitesWithKeywords, and InvitesController#resend_invite.
  module Generator
    GenerationFailed = Class.new(StandardError)

    # Gemini spends part of this budget on an internal reasoning step before
    # any visible text is produced. thinking_effort: "none" below asks for
    # the lowest reasoning effort the model supports, but confirmed in
    # production (AiApiAuditLog, finishReason) that reasoning can still eat
    # enough of a tight budget to truncate mid-BODY, before the join link is
    # ever written -- 57% of real calls hit MAX_TOKENS before this was
    # raised to the current default. Admin-configurable (see
    # bulk_invite_ai_personalization_max_tokens) since the right budget
    # depends on the model and rules in use at a given site.
    TEMPERATURE = 0.9

    def self.personalize(invite, extra_keywords: nil)
      return nil if invite.skip_personalization?
      return nil unless enabled?

      link = invite.link(with_email_token: !Invite.email_code_enabled?)
      base_text = render_base_template(link)
      return nil if base_text.blank?

      llm = resolve_llm
      return nil if llm.nil?

      # The real link is stripped out entirely, with nothing in its place,
      # before this reaches the LLM -- it doesn't need any link-shaped
      # context to write a note; the real link is appended afterward by
      # ResponseValidator regardless of what the model writes.
      base_text_without_link = base_text.gsub(link, "")
      response = call_llm(llm, invite, base_text_without_link, extra_keywords: extra_keywords)
      if response.blank?
        raise GenerationFailed,
              "invite #{invite.id}: empty/blank LLM response (no usable text part -- check AiApiAuditLog finishReason)"
      end

      parsed = parse_response(response)
      if parsed.nil?
        raise GenerationFailed,
              "invite #{invite.id}: response did not contain a parseable SUBJECT:/BODY: pair -- " \
                "raw[0..200]=#{response[0..200].inspect}"
      end

      domain = recipient_domain(invite)
      body =
        ResponseValidator.clean_body(
          parsed[:body],
          required_link: link,
          invite_id: invite.id,
          recipient_domain: domain,
        )
      if body.nil?
        raise GenerationFailed,
              "invite #{invite.id}: body failed validation (see preceding rejection log line)"
      end

      subject =
        ResponseValidator.clean_subject(
          parsed[:subject],
          invite_id: invite.id,
          recipient_domain: domain,
        )
      if subject.nil?
        raise GenerationFailed,
              "invite #{invite.id}: subject failed validation (see preceding rejection log line)"
      end

      { subject: subject, body: body }
    rescue GenerationFailed
      raise
    rescue StandardError => e
      Rails.logger.warn(
        "[BulkInvitePersonalization] failed to personalize invite #{invite.id}: #{e.class}: #{e.message}",
      )
      raise GenerationFailed, "#{e.class}: #{e.message}"
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

    # Substitutes the same %{...} placeholder vocabulary a real mailer
    # template uses (site_title/site_description/invite_link) into the
    # admin-configured base template. Tolerant of an unrecognized token --
    # left as literal text rather than raising, since Ruby's String#% is
    # all-or-nothing and a typo in the setting shouldn't break every send.
    def self.render_base_template(link)
      template = SiteSetting.bulk_invite_ai_personalization_template
      return nil if template.blank?

      values = {
        site_title: SiteSetting.title,
        site_description: SiteSetting.site_description,
        invite_link: link,
      }

      template.gsub(/%\{(\w+)\}/) { values.fetch($1.to_sym) { "%{#{$1}}" }.to_s }
    end
    private_class_method :render_base_template

    def self.call_llm(llm, invite, base_text, extra_keywords: nil)
      prompt =
        DiscourseAi::Completions::Prompt.new(
          system_message(base_text),
          messages: [
            { type: :user, content: user_message(invite, extra_keywords: extra_keywords) },
          ],
        )

      response =
        llm.generate(
          prompt,
          user: invite.invited_by || Discourse.system_user,
          feature_name: "bulk_invite_personalization",
          max_tokens: SiteSetting.bulk_invite_ai_personalization_max_tokens,
          temperature: TEMPERATURE,
          thinking_effort: "none",
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

    def self.system_message(base_text)
      <<~TEXT
        You are rewriting an invitation email for one specific recipient,
        working from a base email an admin has provided. Follow every rule
        below exactly.

        #{SiteSetting.bulk_invite_ai_personalization_rules}

        Respond in exactly this format, with no other text before or after:

        SUBJECT: <a short, varied subject line>
        BODY:
        <the reworded email body>

        The real join link is appended automatically, verbatim, on its own
        line, immediately after BODY -- never write the link, a URL, or
        any other link/domain/attachment yourself. End BODY with a
        sentence that naturally leads into the link appearing right after
        it (e.g. an invitation to take a look or join), rather than
        describing or repeating the link.

        Base email to rework (any link has been removed from it entirely --
        the real link is appended automatically after your BODY, per the
        instruction above; preserve the email's core message and
        call-to-action, but rewrite it fully in your own words per the
        rules above):

        #{base_text}
      TEXT
    end
    private_class_method :system_message

    # Splits a "SUBJECT: ...\nBODY:\n..." response into its two parts.
    # Unparseable -- the model didn't follow the format -- returns nil,
    # which #personalize turns into a raised GenerationFailed rather than a
    # silent fallback. Ruby's /m makes "." match newlines (so BODY can span
    # multiple lines); ^/$ are always per-line regardless of /m.
    def self.parse_response(text)
      match = text.match(/\A\s*SUBJECT:\s*(?<subject>.*?)\s*\n\s*BODY:\s*(?<body>.*)\z/im)
      return nil if match.nil?

      subject = match[:subject].to_s.strip
      body = match[:body].to_s.strip
      return nil if subject.blank? || body.blank?

      { subject: subject, body: body }
    end
    private_class_method :parse_response

    # allow_any_email rows store the real address in `description`, not
    # `email` (which is nil so the invite is redeemable by anyone -- see
    # Jobs::BulkInvite#send_invite) -- fall back to it so these rows don't
    # silently lose domain context from the prompt.
    def self.recipient_domain(invite)
      recipient_address = invite.email.presence || invite.description
      recipient_address.to_s.split("@").last
    end
    private_class_method :recipient_domain

    def self.user_message(invite, extra_keywords: nil)
      lines = ["Recipient email domain: #{recipient_domain(invite)}"]
      lines << "Recipient name: #{invite.recipient_name}" if invite.recipient_name.present?

      # extra_keywords is a one-off, per-resend addition (see
      # InvitesController#resend_invite/#resend_all_invites) -- it's never
      # persisted, unlike invite.recipient_keywords, so both can be present
      # and are combined rather than one overriding the other.
      keywords = [invite.recipient_keywords, extra_keywords].select(&:present?).join(", ")
      lines << "Additional context: #{keywords}" if keywords.present?

      lines.join("\n")
    end
    private_class_method :user_message
  end
end
