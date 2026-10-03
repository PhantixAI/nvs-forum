# frozen_string_literal: true

class InviteMailer < ActionMailer::Base
  include Email::BuildEmailHelper

  layout "email_template"

  # `to` overrides the recipient for invites with no bound email (invite.email nil).
  def send_invite(invite, invite_to_topic: false, to: nil)
    # Find the first topic they were invited to
    first_topic = invite.topics.order(:created_at).first

    # get invitee name (based on site setting)
    inviter_name = invite.invited_by.username
    if SiteSetting.enable_names && invite.invited_by.name.present?
      inviter_name = "#{invite.invited_by.name} (#{invite.invited_by.username})"
    end

    sanitized_message =
      (
        if invite.custom_message.present?
          ActionView::Base.full_sanitizer.sanitize(invite.custom_message.gsub(/\n+/, " ").strip)
        else
          nil
        end
      )

    # If they were invited to a topic
    if invite_to_topic && first_topic.present?
      # get topic excerpt
      topic_excerpt = ""
      topic_excerpt = first_topic.excerpt.tr("\n", " ") if first_topic.excerpt

      topic_title = first_topic.try(:title)
      if SiteSetting.private_email?
        topic_title = I18n.t("system_messages.private_topic_title", id: first_topic.id)
        topic_excerpt = ""
      end

      build_email(
        to || invite.email,
        template: sanitized_message ? "custom_invite_mailer" : "invite_mailer",
        inviter_name: inviter_name,
        site_domain_name: Discourse.current_hostname,
        invite_link: invite.link(with_email_token: !Invite.email_code_enabled?),
        topic_title: topic_title,
        topic_excerpt: topic_excerpt,
        site_description: SiteSetting.site_description,
        site_title: SiteSetting.title,
        user_custom_message: sanitized_message,
        invite_id: invite.id,
      )
    else
      default_template =
        DiscoursePluginRegistry.apply_modifier(
          :invite_forum_mailer_template,
          "invite_forum_mailer",
          invite,
        )

      # Which template applies is decided by these two flags directly, not
      # by inferring from whether custom_message happens to be present --
      # that field can be stale, or admin-typed independent of either flag
      # (see ALLOWED_BULK_INVITE_COLUMNS), so a presence check alone can't
      # tell an AI-authored full body from an unrelated manual note.
      ai_active =
        SiteSetting.bulk_invite_ai_personalization_enabled && !invite.skip_personalization?

      template =
        if ai_active && sanitized_message
          "ai_personalized_invite_forum_mailer"
        elsif !ai_active && sanitized_message
          "custom_invite_forum_mailer"
        else
          default_template
        end

      build_email(
        to || invite.email,
        template: template,
        inviter_name: inviter_name,
        site_domain_name: Discourse.current_hostname,
        invite_link: invite.link(with_email_token: !Invite.email_code_enabled?),
        site_description: SiteSetting.site_description,
        site_title: SiteSetting.title,
        user_custom_message: sanitized_message,
        subject_override: ai_active ? invite.custom_subject : nil,
        invite_id: invite.id,
      )
    end
  end

  def send_password_instructions(user)
    if user.present?
      email_token =
        user.email_tokens.create!(email: user.email, scope: EmailToken.scopes[:password_reset])
      build_email(
        user.email,
        template: "invite_password_instructions",
        email_token: email_token.token,
      )
    end
  end
end
