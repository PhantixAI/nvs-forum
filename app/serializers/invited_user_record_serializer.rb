# frozen_string_literal: true

class InvitedUserRecordSerializer < BasicUserSerializer
  attributes :topics_entered, :posts_read_count, :last_seen_at, :email

  attr_accessor :invited_by

  def topics_entered
    object.user_stat.topics_entered
  end

  def include_topics_entered?
    can_see_invite_details?
  end

  def posts_read_count
    object.user_stat.posts_read_count
  end

  def include_posts_read_count?
    can_see_invite_details?
  end

  def include_last_seen_at?
    can_see_profile?
  end

  def include_email?
    options[:show_emails] && can_see_invite_details?
  end

  private

  def can_see_profile?
    (scope || Guardian.new).can_see_profile?(object)
  end

  def can_see_invite_details?
    @can_see_invite_details ||= scope.can_see_invite_details?(invited_by)
  end
end
