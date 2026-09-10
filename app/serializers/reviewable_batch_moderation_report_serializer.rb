# frozen_string_literal: true

class ReviewableBatchModerationReportSerializer < ReviewableSerializer
  attributes :target_user

  payload_attributes(:reason)

  def target_user
    FlaggedUserSerializer.new(object.target, scope: scope, root: false).as_json
  end

  def include_target_user?
    object.target.present?
  end
end
