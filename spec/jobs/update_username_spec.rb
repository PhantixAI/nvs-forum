# frozen_string_literal: true

RSpec.describe Jobs::UpdateUsername do
  fab!(:user)

  it "does not do anything if user_id is invalid" do
    events =
      DiscourseEvent.track_events do
        described_class.new.execute(
          user_id: -999,
          old_username: user.username,
          new_username: "somenewusername",
          avatar_template: user.avatar_template,
        )
      end

    expect(events).to eq([])
  end

  it "does not rewrite similar mentions when the old username contains a dot" do
    renamed_user = Fabricate(:user, username: "foo.bar")
    Fabricate(:user, username: "foo-bar")
    author = Fabricate(:user)
    topic = Fabricate(:topic, user: author)

    Jobs.run_immediately!
    UserActionManager.enable
    post = create_post(user: author, topic: topic, raw: "@foo.bar @foo-bar")

    described_class.new.execute(
      user_id: renamed_user.id,
      old_username: renamed_user.username,
      new_username: "newname",
      avatar_template: renamed_user.avatar_template,
    )

    post.reload

    expect(post.raw).to eq("@newname @foo-bar")
    expect(post.cooked).to match_html <<~HTML
      <p><a class="mention" href="/u/newname">@newname</a> <a class="mention" href="/u/foo-bar">@foo-bar</a></p>
    HTML
  end

  it "updates the category description when a category description topic mentions the user" do
    category = Fabricate(:category_with_definition, user: Discourse.system_user)
    first_post = category.topic.first_post
    first_post.revise(first_post.user, { raw: "This category is managed by @#{user.username}" })
    category.reload

    expect(category.description).to include(user.username)

    old_username = user.username
    new_username = "new_username_123"

    described_class.new.execute(
      user_id: user.id,
      old_username:,
      new_username:,
      avatar_template: user.avatar_template,
    )
    category.reload

    expect(category.description).to include(new_username)
    expect(category.description).not_to include(old_username)
  end

  it "updates the usernames stored in batch moderation notifications" do
    recipient = Fabricate(:admin)
    old_username = user.username
    other_notification = Fabricate(:notification, user: recipient, notification_type: 1)
    other_data = other_notification.data

    status_change =
      Notification.create!(
        user: recipient,
        notification_type: Notification.types[:batch_moderation_status_change],
        data: {
          granted: true,
          actor_username: old_username,
          user_username: old_username,
          user_id: user.id,
        }.to_json,
      )
    action =
      Notification.create!(
        user: recipient,
        notification_type: Notification.types[:batch_moderation_action],
        data: {
          action: "suspend",
          actor_username: "someone",
          target_username: old_username,
        }.to_json,
      )

    described_class.new.execute(
      user_id: user.id,
      old_username:,
      new_username: "renamed_user",
      avatar_template: user.avatar_template,
    )

    expect(Notification.find(status_change.id).data_hash).to include(
      actor_username: "renamed_user",
      user_username: "renamed_user",
    )
    expect(Notification.find(action.id).data_hash).to include(
      actor_username: "someone",
      target_username: "renamed_user",
    )
    expect(other_notification.reload.data).to eq(other_data)
  end
end
