# frozen_string_literal: true

module DiscourseAi
  module Completions
    module Endpoints
      class GoogleVertexAi < Gemini
        METADATA_TOKEN_URL =
          "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
        ADC_TOKEN_EXPIRY_BUFFER_SECONDS = 60

        SERVICE_ACCOUNT_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
        SERVICE_ACCOUNT_OAUTH_SCOPE = "https://www.googleapis.com/auth/cloud-platform"
        SERVICE_ACCOUNT_TOKEN_EXPIRY_BUFFER_SECONDS = 60

        class << self
          def can_contact?(llm_model)
            llm_model.provider == "google_vertex_ai"
          end

          def supports_environment_credentials?
            true
          end

          def requires_configured_url?
            false
          end

          # Deliberately process-local: this is a machine-identity credential,
          # so it must not be shared through Redis or across processes that
          # could run under different service accounts.
          def adc_token
            return @adc_token if @adc_token && @adc_token_expires_at.after?(Time.zone.now)

            reset_adc_token_cache!

            payload = fetch_adc_token_payload
            token = payload&.dig("access_token")
            expires_in = payload&.dig("expires_in").to_i - ADC_TOKEN_EXPIRY_BUFFER_SECONDS

            if token.present? && expires_in > 0
              @adc_token = token
              @adc_token_expires_at = expires_in.seconds.from_now
            end

            @adc_token
          end

          def reset_adc_token_cache!
            @adc_token = nil
            @adc_token_expires_at = nil
          end

          # Returns the parsed service-account hash if `value` looks like one,
          # else nil -- lets access_token tell a pasted service-account JSON
          # key apart from a literal pre-minted bearer token without changing
          # the credential storage/UI at all.
          def parse_service_account_json(value)
            parsed = JSON.parse(value)
            parsed.is_a?(Hash) && parsed["type"] == "service_account" ? parsed : nil
          rescue JSON::ParserError
            nil
          end

          # Unlike adc_token, this is an explicit, admin-supplied credential
          # rather than implicit host identity, so it's safe -- and
          # preferable, to avoid every process minting its own -- to share
          # the minted token across processes via Discourse.cache.
          def service_account_token(service_account_info)
            cache_key = service_account_token_cache_key(service_account_info)
            cached = Discourse.cache.read(cache_key)
            return cached if cached.present?

            payload = fetch_service_account_token_payload(service_account_info)
            token = payload&.dig("access_token")
            expires_in =
              payload&.dig("expires_in").to_i - SERVICE_ACCOUNT_TOKEN_EXPIRY_BUFFER_SECONDS

            if token.present? && expires_in > 0
              Discourse.cache.write(cache_key, token, expires_in: expires_in)
            end

            token
          end

          private

          def fetch_adc_token_payload
            uri = URI(METADATA_TOKEN_URL)
            request = Net::HTTP::Get.new(uri)
            request["Metadata-Flavor"] = "Google"

            response =
              Net::HTTP.start(uri.hostname, uri.port, read_timeout: 2, open_timeout: 2) do |http|
                http.request(request)
              end

            if response.is_a?(Net::HTTPSuccess)
              JSON.parse(response.body)
            else
              Rails.logger.warn(
                "DiscourseAi::GoogleVertexAi: ADC token request failed with status #{response.code}",
              )
              nil
            end
          rescue StandardError => e
            Rails.logger.warn(
              "DiscourseAi::GoogleVertexAi: Failed to fetch ADC token: #{e.message}",
            )
            nil
          end

          def service_account_token_cache_key(service_account_info)
            "vertex-ai-service-account-token-#{Digest::SHA256.hexdigest(service_account_info["client_email"].to_s)}"
          end

          def fetch_service_account_token_payload(service_account_info)
            now = Time.now.to_i
            jwt_payload = {
              iss: service_account_info["client_email"],
              scope: SERVICE_ACCOUNT_OAUTH_SCOPE,
              aud: SERVICE_ACCOUNT_OAUTH_TOKEN_URL,
              iat: now,
              exp: now + 3600,
            }
            assertion =
              JWT.encode(
                jwt_payload,
                OpenSSL::PKey::RSA.new(service_account_info["private_key"]),
                "RS256",
              )

            uri = URI.parse(SERVICE_ACCOUNT_OAUTH_TOKEN_URL)
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
              JSON.parse(response.body)
            else
              Rails.logger.error(
                "DiscourseAi::GoogleVertexAi: Service account token request failed with status #{response.code}",
              )
              nil
            end
          rescue StandardError => e
            Rails.logger.error(
              "DiscourseAi::GoogleVertexAi: Failed to fetch service account token: #{e.message}",
            )
            nil
          end
        end

        def provider_id
          AiApiAuditLog::Provider::Gemini
        end

        private

        def model_uri
          project_id = llm_model.lookup_custom_param("project_id")
          region = llm_model.lookup_custom_param("region")
          model_name = vertex_model_name

          base_url =
            "#{vertex_api_base_url(region)}/v1/projects/#{project_id}/locations/#{region}/publishers/google/models/#{model_name}"

          url =
            if @streaming_mode
              "#{base_url}:streamGenerateContent?alt=sse"
            else
              "#{base_url}:generateContent"
            end

          URI(url)
        end

        def vertex_model_name
          llm_model.name.to_s.sub(%r{\Agoogle/}, "")
        end

        def vertex_api_base_url(region)
          return "https://aiplatform.googleapis.com" if region == "global"

          "https://#{region}-aiplatform.googleapis.com"
        end

        def prepare_request(payload)
          headers = {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer #{access_token}",
          }

          Net::HTTP::Post.new(model_uri, headers).tap { |r| r.body = payload }
        end

        def access_token
          @access_token ||=
            begin
              key = llm_model.api_key
              if key.present?
                service_account_info = self.class.parse_service_account_json(key)
                service_account_info ? self.class.service_account_token(service_account_info) : key
              else
                self.class.adc_token
              end
            end
        end
      end
    end
  end
end
