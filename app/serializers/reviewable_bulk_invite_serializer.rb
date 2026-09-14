# frozen_string_literal: true

class ReviewableBulkInviteSerializer < ReviewableSerializer
  payload_attributes(:invites, :raw_csv)
end
