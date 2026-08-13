# frozen_string_literal: true

RSpec.describe Jobs::DeliverPushNotification do
  fab!(:user)
  fab!(:post)

  let(:payload) do
    {
      "notification_type" => 1,
      "post_url" => "/t/#{post.topic_id}/#{post.post_number}",
      "excerpt" => "Hello you",
    }
  end

  before do
    freeze_time
    SiteSetting.push_notification_time_window_mins = 5
  end

  describe "time window gate" do
    fab!(:time_window_push_subscription) { Fabricate(:push_subscription, user: user) }

    it "does not deliver when user is missing" do
      PushNotificationPusher.expects(:push).never
      FcmPushNotificationPusher.expects(:push).never
      ApnsPushNotificationPusher.expects(:push).never
      Jobs::DeliverPushNotification.new.execute(user_id: -999, payload: payload)
    end

    it "does not deliver when user was recently seen" do
      user.update!(last_seen_at: 1.minute.ago)
      PushNotificationPusher.expects(:push).never
      FcmPushNotificationPusher.expects(:push).never
      ApnsPushNotificationPusher.expects(:push).never
      Jobs::DeliverPushNotification.new.execute(user_id: user.id, payload: payload)
    end

    it "delivers when user is offline" do
      user.update!(last_seen_at: 10.minutes.ago)
      PushNotificationPusher.expects(:push).with(user, payload)
      FcmPushNotificationPusher.expects(:push).with(user, payload)
      ApnsPushNotificationPusher.expects(:push).with(user, payload)
      Jobs::DeliverPushNotification.new.execute(user_id: user.id, payload: payload)
    end

    it "delivers when bypass_time_window is true despite user being active" do
      user.update!(last_seen_at: 1.minute.ago)
      PushNotificationPusher.expects(:push).with(user, payload)
      FcmPushNotificationPusher.expects(:push).with(user, payload)
      ApnsPushNotificationPusher.expects(:push).with(user, payload)

      Jobs::DeliverPushNotification.new.execute(
        user_id: user.id,
        bypass_time_window: true,
        payload: payload,
      )
    end
  end

  describe "web push delivery" do
    before { user.update!(last_seen_at: 10.minutes.ago) }

    it "calls PushNotificationPusher when user has push subscriptions" do
      Fabricate(:push_subscription, user: user)
      PushNotificationPusher.expects(:push).with(user, payload).once
      Jobs::DeliverPushNotification.new.execute(user_id: user.id, payload: payload)
    end

    it "does not call PushNotificationPusher when user has no push subscriptions" do
      PushNotificationPusher.expects(:push).never
      Jobs::DeliverPushNotification.new.execute(user_id: user.id, payload: payload)
    end
  end

  describe "mobile push delivery" do
    before { user.update!(last_seen_at: 10.minutes.ago) }

    it "calls FcmPushNotificationPusher and ApnsPushNotificationPusher" do
      FcmPushNotificationPusher.expects(:push).with(user, payload).once
      ApnsPushNotificationPusher.expects(:push).with(user, payload).once
      Jobs::DeliverPushNotification.new.execute(user_id: user.id, payload: payload)
    end
  end

  describe "both mechanisms" do
    it "delivers via web push and mobile pushers for the same user" do
      user.update!(last_seen_at: 10.minutes.ago)
      Fabricate(:push_subscription, user: user)

      PushNotificationPusher.expects(:push).with(user, payload).once
      FcmPushNotificationPusher.expects(:push).with(user, payload).once
      ApnsPushNotificationPusher.expects(:push).with(user, payload).once

      Jobs::DeliverPushNotification.new.execute(user_id: user.id, payload: payload)
    end
  end

  describe "content localization" do
    fab!(:topic) { Fabricate(:topic, title: "Original topic title") }
    fab!(:localized_post) { Fabricate(:post, topic: topic, raw: "Original post content") }

    let(:localizable_payload) do
      {
        "notification_type" => 1,
        "post_url" => "/t/#{topic.id}/#{localized_post.post_number}",
        "topic_title" => topic.title,
        "topic_id" => topic.id,
        "post_id" => localized_post.id,
        "excerpt" => "Original post content",
        "username" => "system",
        "post_number" => localized_post.post_number,
      }
    end

    before do
      SiteSetting.content_localization_enabled = true
      SiteSetting.allow_user_locale = true
      user.update!(last_seen_at: 10.minutes.ago, locale: "ja")
    end

    it "localizes payload before delivering to web push" do
      Fabricate(:push_subscription, user: user)
      Fabricate(
        :topic_localization,
        topic: topic,
        locale: "ja",
        title: "ローカライズされたトピック",
        fancy_title: "ローカライズされたトピック",
      )
      Fabricate(
        :post_localization,
        post: localized_post,
        locale: "ja",
        raw: "ローカライズされた投稿",
        cooked: "<p>ローカライズされた投稿</p>",
      )

      PushNotificationPusher
        .expects(:push)
        .with { |u, p| p[:topic_title] == "ローカライズされたトピック" && p[:excerpt] == "ローカライズされた投稿" }
        .once

      Jobs::DeliverPushNotification.new.execute(user_id: user.id, payload: localizable_payload)
    end

    it "localizes payload before delivering to FCM push" do
      SiteSetting.fcm_service_account_json = {
        project_id: "test-project",
        client_email: "fcm@test-project.iam.gserviceaccount.com",
        private_key: OpenSSL::PKey::RSA.new(2048).to_pem,
      }.to_json
      FcmPushNotificationPusher.instance_variable_set(:@service_account, nil)
      Discourse.cache.delete(FcmPushNotificationPusher::ACCESS_TOKEN_CACHE_KEY)

      client = Fabricate(:user_api_key_client)
      Fabricate(
        :user_api_key,
        user: user,
        scopes: ["notifications"].map { |name| UserApiKeyScope.new(name: name) },
        push_url: "android",
        user_api_key_client_id: client.id,
      )
      Fabricate(
        :topic_localization,
        topic: topic,
        locale: "ja",
        title: "ローカライズされたトピック",
        fancy_title: "ローカライズされたトピック",
      )

      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(
        status: 200,
        body: { access_token: "test-access-token" }.to_json,
      )

      body = nil
      stub_request(
        :post,
        "https://fcm.googleapis.com/v1/projects/test-project/messages:send",
      ).to_return do |request|
        body = JSON.parse(request.body)
        { status: 200 }
      end

      Jobs::DeliverPushNotification.new.execute(user_id: user.id, payload: localizable_payload)

      expect(body["message"]["notification"]["title"]).to include("ローカライズされたトピック")
    end

    it "does not localize when content_localization_enabled is false" do
      SiteSetting.content_localization_enabled = false
      Fabricate(:push_subscription, user: user)
      Fabricate(
        :topic_localization,
        topic: topic,
        locale: "ja",
        title: "ローカライズされたトピック",
        fancy_title: "ローカライズされたトピック",
      )

      PushNotificationPusher
        .expects(:push)
        .with do |u, p|
          p[:topic_title] == "Original topic title" || p["topic_title"] == "Original topic title"
        end
        .once

      Jobs::DeliverPushNotification.new.execute(user_id: user.id, payload: localizable_payload)
    end
  end
end
