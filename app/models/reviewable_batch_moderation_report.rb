# frozen_string_literal: true

class ReviewableBatchModerationReport < Reviewable
  include ReviewableActionBuilder

  def self.report!(actor:, target:, reason:)
    needs_review!(
      target: target,
      created_by: actor,
      reviewable_by_moderator: true,
      payload: {
        reason: reason,
      },
    )
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
