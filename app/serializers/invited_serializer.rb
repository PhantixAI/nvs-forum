# frozen_string_literal: true

class InvitedSerializer < ApplicationSerializer
  attributes :invites, :can_see_invite_details, :counts, :available_domains

  def invites
    ActiveModel::ArraySerializer.new(
      object.invite_list,
      each_serializer:
        (
          if object.type == "pending" || object.type == "expired"
            InviteSerializer
          else
            InvitedUserSerializer
          end
        ),
      scope: scope,
      root: false,
      show_emails: object.show_emails,
      email_logs_by_invite_id: object.email_logs_by_invite_id,
    ).as_json
  end

  def can_see_invite_details
    scope.can_see_invite_details?(object.inviter)
  end

  def counts
    object.counts
  end

  def available_domains
    object.available_domains
  end
end
