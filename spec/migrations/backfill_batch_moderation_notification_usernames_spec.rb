# frozen_string_literal: true

require Rails.root.join(
          "db/migrate/20260919061443_backfill_batch_moderation_notification_usernames.rb",
        )

RSpec.describe BackfillBatchModerationNotificationUsernames do
  fab!(:recipient, :admin)
  fab!(:user)

  before do
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  after { ActiveRecord::Migration.verbose = @original_verbose }

  # The ids these types had when this migration ran; Notification.types has
  # since moved them (see RenumberBatchModerationNotificationTypes).
  HISTORICAL_TYPE_IDS = {
    batch_moderation_action: 46,
    batch_moderation_cohort_change: 47,
    batch_moderation_status_change: 48,
  }.freeze

  def create_notification(type, data)
    Notification.create!(
      user: recipient,
      notification_type: HISTORICAL_TYPE_IDS.fetch(type),
      data: data.to_json,
    )
  end

  it "points stale usernames at each user's current username" do
    status_change =
      create_notification(
        :batch_moderation_status_change,
        granted: true,
        user_username: "old_name",
        user_id: user.id,
      )
    cohort_change =
      create_notification(
        :batch_moderation_cohort_change,
        joined: true,
        user_username: "older_name",
        user_id: user.id,
      )
    action =
      create_notification(
        :batch_moderation_action,
        action: "suspend",
        actor_username: "someone",
        target_username: "old_name",
        target_user_id: user.id,
      )

    described_class.new.up

    expect(Notification.find(status_change.id).data_hash[:user_username]).to eq(user.username)
    expect(Notification.find(cohort_change.id).data_hash[:user_username]).to eq(user.username)
    expect(Notification.find(action.id).data_hash).to include(
      actor_username: "someone",
      target_username: user.username,
    )
  end

  it "leaves notifications alone when the user no longer exists" do
    orphan =
      create_notification(
        :batch_moderation_status_change,
        granted: true,
        user_username: "gone",
        user_id: -999,
      )

    described_class.new.up

    expect(Notification.find(orphan.id).data_hash[:user_username]).to eq("gone")
  end
end
