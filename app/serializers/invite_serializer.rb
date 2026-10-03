# frozen_string_literal: true

class InviteSerializer < ApplicationSerializer
  attributes :id,
             :invite_key,
             :link,
             :description,
             :email,
             :domain,
             :emailed,
             :delivery_status,
             :can_delete_invite,
             :max_redemptions_allowed,
             :redemption_count,
             :custom_message,
             :created_at,
             :updated_at,
             :expires_at,
             :expired,
             :grants_admin,
             :grants_moderator

  has_many :topics, embed: :object, serializer: BasicTopicSerializer
  has_many :groups, embed: :object, serializer: BasicGroupSerializer

  def include_invite_key?
    can_see_invite_details?
  end

  def include_link?
    can_see_invite_details?
  end

  def include_description?
    can_see_invite_details?
  end

  def include_email?
    options[:show_emails] && !object.redeemed? && can_see_invite_emails?
  end

  def include_domain?
    can_see_invite_details?
  end

  def include_emailed?
    has_recipient? && can_see_invite_details?
  end

  def emailed
    object.emailed_status != Invite.emailed_status_types[:not_required]
  end

  def include_delivery_status?
    has_recipient? && can_see_invite_details?
  end

  def delivery_status
    # Passing an explicit nil would defeat Invite#delivery_status's own
    # default argument (falling back to latest_sent_email_log) -- only pass
    # an argument at all when a preload hash was actually given.
    if options[:email_logs_by_invite_id]
      object.delivery_status(options[:email_logs_by_invite_id][object.id])
    else
      object.delivery_status
    end
  end

  def can_delete_invite
    scope.can_destroy_invite?(object)
  end

  def include_custom_message?
    email.present? && can_see_invite_details?
  end

  def include_max_redemptions_allowed?
    email.blank? && can_see_invite_details?
  end

  def include_redemption_count?
    email.blank? && can_see_invite_details?
  end

  def include_topics?
    can_see_invite_details?
  end

  def topics
    object.topics.select { |topic| scope.can_see?(topic) }
  end

  def include_groups?
    can_see_invite_details?
  end

  def expired
    object.expired?
  end

  def grants_admin
    object.admin?
  end

  def include_grants_admin?
    can_see_invite_details?
  end

  def grants_moderator
    object.moderator?
  end

  def include_grants_moderator?
    can_see_invite_details?
  end

  private

  def can_see_invite_details?
    return @can_see_invite_details if defined?(@can_see_invite_details)

    @can_see_invite_details = scope.can_see_invite_details?(object.invited_by)
  end

  # An allow_any_email invite is unbound (email: nil) by design -- its intended
  # recipient lives in description instead (see Jobs::BulkInvite#send_invite,
  # Invite.search_filter, Jobs::InviteEmail). Gating emailed/delivery_status on
  # email.present? alone hid both for every such invite that was actually sent,
  # even though bulk "Resend Invites" already resends them correctly.
  def has_recipient?
    email.present? || object.description.present?
  end

  def can_see_invite_emails?
    return @can_see_invite_emails if defined?(@can_see_invite_emails)

    @can_see_invite_emails = scope.can_see_invite_emails?(object.invited_by)
  end
end
