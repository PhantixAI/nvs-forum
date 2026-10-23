# frozen_string_literal: true

RSpec.describe Jobs::RequeueStaleDraftingInvites do
  it "delegates to Invite.requeue_stale_drafting" do
    Invite.expects(:requeue_stale_drafting)

    described_class.new.execute({})
  end
end
