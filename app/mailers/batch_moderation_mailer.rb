# frozen_string_literal: true

class BatchModerationMailer < ActionMailer::Base
  include Email::BuildEmailHelper

  def action_taken(to_user, actor:, target:, action:, reason:)
    build_email(
      to_user.email,
      template: "batch_moderation_action_mailer",
      action_title: I18n.t("batch_moderation.actions.#{action}"),
      actor_username: actor.username,
      target_username: target.username,
      reason: reason,
      target_url: "#{Discourse.base_url}/u/#{target.username}",
    )
  end

  def cohort_change(to_user, user:, group:, joined:)
    build_email(
      to_user.email,
      template: "batch_moderation_cohort_change_mailer",
      action_title: I18n.t("batch_moderation.actions.#{joined ? "cohort_joined" : "cohort_left"}"),
      user_username: user.username,
      group_name: group.full_name,
      target_url: "#{Discourse.base_url}/u/#{user.username}",
    )
  end

  def status_change(to_user, actor:, user:, group:, granted:)
    build_email(
      to_user.email,
      template: "batch_moderation_status_change_mailer",
      action_title:
        I18n.t("batch_moderation.actions.#{granted ? "moderator_granted" : "moderator_revoked"}"),
      actor_username: actor&.username || I18n.t("batch_moderation.system_actor"),
      user_username: user.username,
      group_name: group.full_name,
      target_url: "#{Discourse.base_url}/u/#{user.username}",
    )
  end
end
