# frozen_string_literal: true

class ReviewableBulkInvite < Reviewable
  include ReviewableActionBuilder

  def self.submit!(actor:, invites:, raw_csv:)
    needs_review!(
      created_by: actor,
      reviewable_by_moderator: true,
      payload: {
        invites: invites,
        raw_csv: raw_csv,
      },
    )
  end

  def build_combined_actions(actions, guardian, args)
    return unless pending?

    build_action(actions, :approve_bulk_invite, icon: "check", button_class: "btn-primary")
    build_action(actions, :reject_bulk_invite, icon: "xmark", button_class: "btn-danger")
  end

  def perform_approve_bulk_invite(performed_by, _args)
    Jobs.enqueue(:bulk_invite, invites: payload["invites"], current_user_id: created_by_id)
    create_result(:success, :approved)
  end

  def perform_reject_bulk_invite(performed_by, _args)
    SystemMessage.create_from_system_user(
      created_by,
      :reviewable_bulk_invite_rejected,
      invite_count: payload["invites"].size,
    )
    create_result(:success, :rejected)
  end
end
