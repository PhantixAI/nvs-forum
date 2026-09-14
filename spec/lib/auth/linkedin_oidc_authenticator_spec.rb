# frozen_string_literal: true

RSpec.describe Auth::LinkedInOidcAuthenticator do
  let(:hash) do
    OmniAuth::AuthHash.new(
      provider: "linkedin_oidc",
      extra: {
        raw_info: {
          email: "100",
          email_verified: true,
          given_name: "Coding",
          family_name: "Horror",
          picture:
            "https://media.licdn.com/dms/image/C5603AQH7UYSA0m_DNw/profile-displayphoto-shrink_100_100/0/1516350954443?e=1718841600&v=beta&t=1DdwKTzW2QdVuPtnk1C20oaYSkqeEa4ffuI6_NlXbB",
          locale: {
            country: "US",
            language: "en",
          },
        },
      },
      info: {
        email: "coding@horror.com",
        first_name: "Coding",
        last_name: "Horror",
        image:
          "https://media.licdn.com/dms/image/C5603AQH7UYSA0m_DNw/profile-displayphoto-shrink_100_100/0/1516350954443?e=1718841600&v=beta&t=1DdwKTzW2QdVuPtnk1C20oaYSkqeEa4ffuI6_NlXbB",
      },
      uid: "100",
    )
  end

  let(:authenticator) { described_class.new }

  describe "after_authenticate" do
    it "works normally" do
      result = authenticator.after_authenticate(hash)
      expect(result.user).to eq(nil)
      expect(result.failed).to eq(false)
      expect(result.name).to eq("Coding Horror")
      expect(result.email).to eq("coding@horror.com")
    end
  end

  describe "client_options" do
    it "sends client credentials in the token request body, not a Basic Auth header" do
      # The `oauth2` gem defaults to :basic_auth since v2.0, but LinkedIn's
      # token endpoint only accepts client_secret in the POST body.
      client_options =
        Auth::LinkedInOidcAuthenticator::LinkedInOidc.default_options[:client_options]

      expect(client_options[:auth_scheme]).to eq(:request_body)
    end
  end
end
