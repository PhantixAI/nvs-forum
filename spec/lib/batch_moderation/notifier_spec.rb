# frozen_string_literal: true

RSpec.describe BatchModeration::Notifier do
  fab!(:actor, :user)
  fab!(:target, :user)
  fab!(:admin)
  fab!(:moderator)

  describe ".notify_staff!" do
    it "creates an in-app notification for every staff member except the actor" do
      expect {
        described_class.notify_staff!(
          actor: actor,
          target: target,
          action: :suspend,
          reason: "rude",
        )
      }.to change {
        Notification.where(notification_type: Notification.types[:batch_moderation_action]).count
      }.by(2)

      notification =
        admin
          .notifications
          .where(notification_type: Notification.types[:batch_moderation_action])
          .last
      data = JSON.parse(notification.data)
      expect(data["action"]).to eq("suspend")
      expect(data["actor_username"]).to eq(actor.username)
      expect(data["target_username"]).to eq(target.username)
    end

    it "does not notify the actor even if they are staff" do
      described_class.notify_staff!(actor: admin, target: target, action: :silence, reason: "x")

      expect(
        admin.notifications.where(notification_type: Notification.types[:batch_moderation_action]),
      ).to be_empty
    end

    it "sends an email to staff members who have email notifications enabled" do
      Jobs.run_immediately!

      expect {
        described_class.notify_staff!(actor: actor, target: target, action: :report, reason: "rude")
      }.to change { ActionMailer::Base.deliveries.size }.by(2)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.body.encoded).to include(target.username)
      expect(mail.body.encoded).to include(actor.username)
    end

    it "skips email for staff members who disabled email notifications" do
      Jobs.run_immediately!
      moderator.user_option.update!(email_level: UserOption.email_level_types[:never])

      expect {
        described_class.notify_staff!(actor: actor, target: target, action: :report, reason: "rude")
      }.to change { ActionMailer::Base.deliveries.size }.by(1)
    end

    it "enqueues one email job per staff member, without blocking on the send" do
      expect {
        described_class.notify_staff!(actor: actor, target: target, action: :report, reason: "rude")
      }.to change(Jobs::BatchModerationNotifyStaffEmail.jobs, :size).by(2)
    end
  end

  describe ".notify_cohort_change" do
    fab!(:group)
    fab!(:cohort_moderator, :user)

    before { group.add_owner(cohort_moderator) }

    it "notifies admins, moderators, and the cohort's owners, excluding the affected user" do
      expect {
        described_class.notify_cohort_change(user: target, group: group, joined: true)
      }.to change {
        Notification.where(
          notification_type: Notification.types[:batch_moderation_cohort_change],
        ).count
      }.by(3)

      expect(
        target.notifications.where(
          notification_type: Notification.types[:batch_moderation_cohort_change],
        ),
      ).to be_empty

      notification =
        cohort_moderator
          .notifications
          .where(notification_type: Notification.types[:batch_moderation_cohort_change])
          .last
      data = JSON.parse(notification.data)
      expect(data["joined"]).to eq(true)
      expect(data["user_username"]).to eq(target.username)
      expect(data["group_id"]).to eq(group.id)
    end

    it "enqueues one email job per recipient" do
      expect {
        described_class.notify_cohort_change(user: target, group: group, joined: false)
      }.to change(Jobs::BatchModerationNotifyCohortChangeEmail.jobs, :size).by(3)
    end
  end

  describe ".notify_moderator_status_change" do
    fab!(:group)
    fab!(:cohort_moderator, :user)

    before { group.add_owner(cohort_moderator) }

    it "notifies admins, moderators, and the cohort's owners, excluding the actor and the user" do
      expect {
        described_class.notify_moderator_status_change(
          actor: admin,
          user: target,
          group: group,
          granted: true,
        )
      }.to change {
        Notification.where(
          notification_type: Notification.types[:batch_moderation_status_change],
        ).count
      }.by(2)

      expect(
        admin.notifications.where(
          notification_type: Notification.types[:batch_moderation_status_change],
        ),
      ).to be_empty

      notification =
        cohort_moderator
          .notifications
          .where(notification_type: Notification.types[:batch_moderation_status_change])
          .last
      data = JSON.parse(notification.data)
      expect(data["granted"]).to eq(true)
      expect(data["actor_username"]).to eq(admin.username)
      expect(data["user_username"]).to eq(target.username)
    end

    it "handles a nil actor (auto-promotion)" do
      expect {
        described_class.notify_moderator_status_change(
          actor: nil,
          user: target,
          group: group,
          granted: true,
        )
      }.not_to raise_error
    end
  end
end
