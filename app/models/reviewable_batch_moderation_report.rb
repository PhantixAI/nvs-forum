# frozen_string_literal: true

class ReviewableBatchModerationReport < Reviewable
  include ReviewableActionBuilder

  def self.report!(actor:, target:, reason:)
    reviewable =
      needs_review!(
        target: target,
        created_by: actor,
        reviewable_by_moderator: true,
        payload: {
          reason: reason,
        },
      )
    reviewable.record_report!(actor, reason)
    reviewable
  end

  # A reported user has a single reviewable (unique on type and target), so a
  # later report finds the existing row and needs_review! keeps its original
  # payload and creator. Every report is therefore kept here, and `reason`
  # always holds the newest one.
  def record_report!(actor, reason)
    with_lock do
      entry = {
        "reporter_id" => actor.id,
        "reporter_username" => actor.username,
        "reason" => reason,
        "reported_at" => Time.zone.now.iso8601,
      }

      update!(payload: (payload || {}).merge("reason" => reason, "reports" => reports + [entry]))
    end
  end

  def reports
    Array(payload&.dig("reports"))
  end

  def build_combined_actions(actions, guardian, args)
    return unless pending?

    build_action(actions, :agree_report, icon: "thumbs-up")
    build_action(actions, :disagree_report, icon: "thumbs-down")
  end

  def perform_agree_report(performed_by, _args)
    create_result(:success, :approved)
  end

  def perform_disagree_report(performed_by, _args)
    create_result(:success, :rejected)
  end
end
