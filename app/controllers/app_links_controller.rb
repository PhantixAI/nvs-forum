# frozen_string_literal: true

class AppLinksController < ApplicationController
  skip_before_action :check_xhr,
                     :redirect_to_login_if_required,
                     :redirect_to_profile_if_required,
                     :preload_json

  STORE_LINKS = {
    "navodians.com" => {
      ios: "https://apps.apple.com/us/app/navodians/id6789493247",
      android: "https://play.google.com/store/apps/details?id=com.navodians.app",
    },
    "nitians.in" => {
      ios: "https://apps.apple.com/us/app/nitians/id6789495232",
      android: "https://play.google.com/store/apps/details?id=in.nitians.app",
    },
    "iitians.in" => {
      ios: "https://apps.apple.com/us/app/apex-india/id6789490657",
      android: "https://play.google.com/store/apps/details?id=in.iitians.app",
    },
  }.freeze

  def show
    links = STORE_LINKS[current_site_key]

    destination =
      if links.nil?
        Discourse.base_url
      elsif ios_user_agent?
        links[:ios]
      elsif android_user_agent?
        links[:android]
      else
        Discourse.base_url
      end

    redirect_to destination, allow_other_host: true
  end

  private

  # host_names in config/multisite.yml are always the bare domain or
  # `www.`-prefixed; UAT's `uat.`-prefixed hosts should resolve to the same
  # store links as their production counterpart.
  def current_site_key
    STORE_LINKS.keys.find { |host| request.host.end_with?(host) }
  end

  def ios_user_agent?
    request.user_agent.to_s.match?(/iPhone|iPad|iPod/)
  end

  def android_user_agent?
    request.user_agent.to_s.match?(/Android/)
  end
end
