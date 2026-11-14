# frozen_string_literal: true

RSpec.describe AppLinksController do
  let(:ios_user_agent) do
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
  end
  let(:android_user_agent) { "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36" }
  let(:desktop_user_agent) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" }

  describe "#show" do
    it "redirects an iOS user agent to the App Store listing for the current site" do
      get "/get-app", headers: { "HOST" => "nitians.in", "HTTP_USER_AGENT" => ios_user_agent }

      expect(response).to redirect_to("https://apps.apple.com/us/app/nitians/id6789495232")
    end

    it "redirects an Android user agent to the Play Store listing for the current site" do
      get "/get-app", headers: { "HOST" => "iitians.in", "HTTP_USER_AGENT" => android_user_agent }

      expect(response).to redirect_to(
        "https://play.google.com/store/apps/details?id=in.iitians.app",
      )
    end

    it "matches a uat.-prefixed host to the same site's store links" do
      get "/get-app", headers: { "HOST" => "uat.nitians.in", "HTTP_USER_AGENT" => ios_user_agent }

      expect(response).to redirect_to("https://apps.apple.com/us/app/nitians/id6789495232")
    end

    it "redirects a desktop user agent to the site itself" do
      get "/get-app",
          headers: {
            "HOST" => "navodians.com",
            "HTTP_USER_AGENT" => desktop_user_agent,
          }

      expect(response).to redirect_to(Discourse.base_url)
    end

    it "falls back to the site itself when the host doesn't match a known app" do
      get "/get-app", headers: { "HTTP_USER_AGENT" => ios_user_agent }

      expect(response).to redirect_to(Discourse.base_url)
    end

    it "does not match a host that merely ends with a known domain as a substring" do
      get "/get-app", headers: { "HOST" => "shownitians.in", "HTTP_USER_AGENT" => ios_user_agent }

      expect(response).to redirect_to(Discourse.base_url)
    end
  end
end
