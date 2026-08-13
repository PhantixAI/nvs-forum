# frozen_string_literal: true

class FcmPushNotificationPusher
  OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
  OAUTH_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
  ACCESS_TOKEN_CACHE_KEY = "fcm_push_access_token"
  # Google-issued tokens are valid for 1 hour; refresh a bit early.
  ACCESS_TOKEN_TTL_SECONDS = 55 * 60

  def self.push(user, payload)
    return if SiteSetting.fcm_service_account_json.blank?

    client_ids = UserApiKey.push_clients_for(user).select { |_, platform| platform == "android" }
    return if client_ids.empty?

    access_token = fetch_access_token
    return if access_token.blank?

    message = build_message(payload)

    client_ids.each { |client_id, _| send_message(access_token, client_id, message) }
  end

  def self.build_message(payload)
    {
      notification: {
        title: payload[:translated_title] || PushNotificationPusher.title(payload),
        body: payload[:excerpt],
      },
      data: {
        discourse_url: PushNotificationPusher.absolute_post_url(payload),
        topic_id: payload[:topic_id].to_s,
      },
    }
  end

  def self.send_message(access_token, client_id, message)
    project_id = service_account["project_id"]
    uri = URI.parse("https://fcm.googleapis.com/v1/projects/#{project_id}/messages:send")

    http = FinalDestination::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request =
      FinalDestination::HTTP::Post.new(
        uri.request_uri,
        { "Content-Type" => "application/json", "Authorization" => "Bearer #{access_token}" },
      )
    request.body = { message: message.merge(token: client_id) }.to_json

    response = http.request(request)

    if response.code.to_i != 200
      Rails.logger.warn(
        "Failed to push FCM notification to #{client_id} Status: #{response.code}: #{response.body}",
      )
    end
  rescue => e
    Rails.logger.error("An error occurred while pushing an FCM notification: #{e.message}")
  end

  def self.service_account
    @service_account ||= {}
    @service_account[SiteSetting.fcm_service_account_json] ||= JSON.parse(
      SiteSetting.fcm_service_account_json,
    )
  end

  def self.fetch_access_token
    cached = Discourse.cache.read(ACCESS_TOKEN_CACHE_KEY)
    return cached if cached.present?

    token = request_access_token
    if token.present?
      Discourse.cache.write(ACCESS_TOKEN_CACHE_KEY, token, expires_in: ACCESS_TOKEN_TTL_SECONDS)
    end
    token
  end

  def self.request_access_token
    account = service_account
    now = Time.now.to_i

    jwt_payload = {
      iss: account["client_email"],
      scope: OAUTH_SCOPE,
      aud: OAUTH_TOKEN_URL,
      iat: now,
      exp: now + 3600,
    }

    assertion = JWT.encode(jwt_payload, OpenSSL::PKey::RSA.new(account["private_key"]), "RS256")

    uri = URI.parse(OAUTH_TOKEN_URL)
    http = FinalDestination::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request =
      FinalDestination::HTTP::Post.new(
        uri.request_uri,
        { "Content-Type" => "application/x-www-form-urlencoded" },
      )
    request.body =
      URI.encode_www_form(
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: assertion,
      )

    response = http.request(request)

    if response.code.to_i == 200
      JSON.parse(response.body)["access_token"]
    else
      Rails.logger.error(
        "Failed to fetch FCM access token Status: #{response.code}: #{response.body}",
      )
      nil
    end
  rescue => e
    Rails.logger.error("An error occurred while fetching an FCM access token: #{e.message}")
    nil
  end
end
