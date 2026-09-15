# frozen_string_literal: true

module Jobs
  class SyncBatchModerationGroup < ::Jobs::Base
    def execute(args)
      user = User.find_by(id: args[:user_id])
      return if user.nil?

      BatchModeration::GroupSync.sync(user)
    end
  end
end
