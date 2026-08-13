# frozen_string_literal: true

class ApnsPushNotificationPusher
  def self.push(user, payload)
    return if SiteSetting.apple_pem.blank?

    client_ids = UserApiKey.push_clients_for(user).select { |_, platform| platform == "ios" }
    return if client_ids.empty?

    connection = nil
    sandbox_connection = nil

    client_ids.each do |client_id, _|
      connection ||= build_connection
      response = send_notification(connection, client_id, payload)

      # Debug/dev builds installed outside TestFlight/App Store register sandbox
      # APNs tokens, which the production APNs endpoint always rejects with this
      # error — retry once against the sandbox endpoint before giving up.
      if bad_device_token?(response)
        sandbox_connection ||= build_connection(sandbox: true)
        response = send_notification(sandbox_connection, client_id, payload)
      end

      if !response&.ok?
        Rails.logger.warn(
          "Failed to push APNs notification to #{client_id} Status: #{response&.status}: #{response&.body}",
        )
      end
    end
  ensure
    connection&.close
    sandbox_connection&.close
  end

  def self.send_notification(connection, client_id, payload)
    notification = Apnotic::Notification.new(client_id)
    notification.alert = {
      title: payload[:translated_title] || PushNotificationPusher.title(payload),
      body: payload[:excerpt],
    }
    notification.custom_payload = {
      discourse_url: PushNotificationPusher.absolute_post_url(payload),
      topic_id: payload[:topic_id].to_s,
    }
    notification.topic = SiteSetting.apns_bundle_id
    # Explicit immediate delivery — don't rely on APNs' undocumented-in-practice
    # default when these headers are omitted.
    notification.priority = 10
    notification.push_type = "alert"

    connection.push(notification)
  rescue => e
    Rails.logger.error("An error occurred while pushing an APNs notification: #{e.message}")
    nil
  end

  def self.bad_device_token?(response)
    response&.status == "400" && response.body.is_a?(Hash) &&
      response.body["reason"] == "BadDeviceToken"
  end

  def self.build_connection(sandbox: false)
    options = {
      auth_method: :token,
      cert_path: StringIO.new(SiteSetting.apple_pem),
      key_id: SiteSetting.apple_key_id,
      team_id: SiteSetting.apple_team_id,
    }

    sandbox ? Apnotic::Connection.development(options) : Apnotic::Connection.new(options)
  end
end
