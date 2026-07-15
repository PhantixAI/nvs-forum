# frozen_string_literal: true

class BatchModerationController < ApplicationController
  requires_login

  def suspend
    User::Suspend.call(
      guardian: guardian,
      params: {
        user_id: params[:id].to_i,
        reason: params[:reason],
        suspend_until: params[:suspend_until],
      },
    ) do
      on_success do |user:, full_reason:, params:|
        BatchModeration::Notifier.notify_staff!(
          actor: current_user,
          target: user,
          action: :suspend,
          reason: params.reason,
        )
        render_json_dump(
          suspension: {
            suspended_till: user.suspended_till,
            suspended_at: user.suspended_at,
            full_suspend_reason: full_reason,
          },
        )
      end
      on_failed_contract do |contract|
        render json: failed_json.merge(errors: contract.errors.full_messages), status: :bad_request
      end
      on_model_not_found(:user) { raise Discourse::NotFound }
      on_failed_policy(:not_suspended_already) do |policy|
        render json: failed_json.merge(message: policy.reason), status: :conflict
      end
      on_failed_policy(:can_suspend_all_users) { raise Discourse::InvalidAccess.new }
    end
  end

  def silence
    User::Silence.call(
      guardian: guardian,
      params: {
        user_id: params[:id].to_i,
        reason: params[:reason],
        silenced_till: params[:silenced_till],
      },
    ) do
      on_success do |user:, full_reason:, params:|
        BatchModeration::Notifier.notify_staff!(
          actor: current_user,
          target: user,
          action: :silence,
          reason: params.reason,
        )
        render_json_dump(
          silence: {
            silenced: true,
            silenced_till: user.silenced_till,
            silenced_at: user.silenced_at,
            full_silence_reason: full_reason,
          },
        )
      end
      on_failed_contract do |contract|
        render json: failed_json.merge(errors: contract.errors.full_messages), status: :bad_request
      end
      on_model_not_found(:user) { raise Discourse::NotFound }
      on_failed_policy(:not_silenced_already) do |policy|
        render json: failed_json.merge(message: policy.reason), status: :conflict
      end
      on_failed_policy(:can_silence_all_users) { raise Discourse::InvalidAccess.new }
    end
  end

  def report
    target = User.find_by(id: params[:id].to_i)
    raise Discourse::NotFound if target.blank?
    raise Discourse::InvalidAccess if !BatchModeration::Moderator.can_report?(current_user, target)

    reason = params[:reason].to_s.strip
    raise Discourse::InvalidParameters.new(:reason) if reason.blank? || reason.length > 300

    ReviewableBatchModerationReport.report!(actor: current_user, target: target, reason: reason)
    BatchModeration::Notifier.notify_staff!(
      actor: current_user,
      target: target,
      action: :report,
      reason: reason,
    )

    render json: success_json
  end
end
