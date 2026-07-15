# frozen_string_literal: true

require Rails.root.join("db/migrate/20260919101500_renumber_batch_moderation_notification_types.rb")

RSpec.describe RenumberBatchModerationNotificationTypes do
  fab!(:recipient, :admin)

  before do
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  after { ActiveRecord::Migration.verbose = @original_verbose }

  def notification_with_type(type_id)
    Notification.create!(user: recipient, notification_type: type_id, data: {}.to_json)
  end

  it "moves the old ids to the ones Notification.types now uses" do
    action = notification_with_type(46)
    cohort_change = notification_with_type(47)
    status_change = notification_with_type(48)

    described_class.new.up

    expect(action.reload.notification_type).to eq(Notification.types[:batch_moderation_action])
    expect(cohort_change.reload.notification_type).to eq(
      Notification.types[:batch_moderation_cohort_change],
    )
    expect(status_change.reload.notification_type).to eq(
      Notification.types[:batch_moderation_status_change],
    )
  end

  it "leaves other notification types alone and can safely run twice" do
    mention = notification_with_type(Notification.types[:mentioned])
    moved = notification_with_type(46)

    2.times { described_class.new.up }

    expect(mention.reload.notification_type).to eq(Notification.types[:mentioned])
    expect(moved.reload.notification_type).to eq(Notification.types[:batch_moderation_action])
  end
end
