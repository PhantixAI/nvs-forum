# frozen_string_literal: true

class InvitedUserSerializer < ApplicationSerializer
  attributes :id, :redeemed_at, :user, :invite_source, :email

  def id
    object.invite.id
  end

  def user
    ser =
      InvitedUserRecordSerializer.new(
        object.user,
        scope: scope,
        root: false,
        show_emails: options[:show_emails],
      )
    ser.invited_by = object.invite.invited_by
    ser.as_json
  end

  def invite_source
    object.invite.is_invite_link? ? "link" : "email"
  end

  def email
    object.invite.email
  end

  def include_email?
    options[:show_emails] && can_see_invite_emails?
  end

  private

  def can_see_invite_emails?
    scope.can_see_invite_emails?(object.invite.invited_by)
  end
end
