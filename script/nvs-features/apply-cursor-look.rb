# frozen_string_literal: true

# Cursor-forum-like look on the Foundation theme: header search field, Cursor's colours and
# type sizes, darker sidebar, outlined header buttons, and (optionally) Chat and Channels hidden
# from the left sidebar. See custom-feature.md sections 14-15.
# The colours live in one theme-component CSS block. By default they apply on every screen
# size (including phones and the mobile app); DESKTOP_ONLY=1 limits them to 768px and up so
# phones keep the site's default palette. Hiding chat from the sidebar is behind its own
# theme-component setting, "hide_channels_and_chat_from_sidebar" (Admin > Customize > Themes >
# nvs-cursor-look > Settings), defaulted on here but toggleable by an admin afterwards without
# re-running this script -- turning it off restores stock Discourse behaviour (chat back in the
# sidebar). Foundation stays the default theme; nothing is switched. Targets iitians by default;
# the other sites are left alone unless SITES names them.
#
# Run inside the app (local: bin/rails runner script/nvs-features/apply-cursor-look.rb;
# production: copy it into the container, then as the app user
# `cd /var/www/discourse && RAILS_ENV=production bundle exec rails runner /tmp/apply-cursor-look.rb`).
#
#   (default)      report current state only, change nothing
#   APPLY=1        apply everything (idempotent, safe to re-run)
#   ROLLBACK=1     undo: the component link and the two theme settings go back to what an
#                  untouched site has (the component itself is kept, so a re-apply is instant)
#   DESKTOP_ONLY=1 apply the look only from 768px up (phones keep the old palette); without
#                  it the look applies on all screen sizes
#   SITES=a,b,c    which multisite databases (default: iitians)

SITES = ENV.fetch("SITES", "iitians").split(",").map(&:strip)
APPLY = ENV["APPLY"] == "1"
ROLLBACK = ENV["ROLLBACK"] == "1"
DESKTOP_ONLY = ENV["DESKTOP_ONLY"] == "1"
# Discourse's `md` breakpoint is 48rem. Light mode only; the dark palette keeps its colours.
MEDIA =
  (
    if DESKTOP_ONLY
      "(min-width: 48rem) and (prefers-color-scheme: light)"
    else
      "(prefers-color-scheme: light)"
    end
  )

COMPONENT_NAME = "nvs-cursor-look"
# Earlier versions assigned a "Cursor Flat" palette to Foundation (which applied on phones
# too). It is removed on apply so those sites return to the default palette.
OLD_SCHEME_NAME = "Cursor Flat"
FOUNDATION_ID = -1

CSS = <<~'SCSS'.gsub("__MEDIA__", MEDIA)
  // Cursor-forum look, light mode only, on every screen size unless the script was run with
  // DESKTOP_ONLY=1 (then 768px and up). The first group is the palette Cursor uses (its ten base
  // colours compiled to Discourse's derived custom properties: regenerate it if the colours
  // change), the second holds Cursor's own theme tokens for type, sidebar, nav and buttons.
  @media __MEDIA__ {
    // `body` as well as `:root`: the modernize-foundation upcoming change sets its
    // variables on the element that carries its class, which would otherwise win.
    :root,
    body {
      --primary: #26251e;
      --secondary: #f7f7f4;
      --tertiary: #3b3a33;
      // Core styles every plain link (post content, modal/admin help text, anywhere else
      // using a bare <a> without its own colour override) via this one variable
      // (app/assets/stylesheets/common/foundation/base.scss) -- normally var(--tertiary), which
      // this palette makes near-black like --primary (body text), so a link became
      // indistinguishable from surrounding text until hovered. Overriding it directly here
      // (rather than --tertiary itself, which other rules above intentionally reuse for
      // buttons/icons) fixes every link site-wide without touching anything else.
      --d-link-color: #eb5600;
      --header_background: #f7f7f4;
      --header_primary: #7a7974;
      --danger: #eb5600;
      --success: #009900;
      --love: #de9bdf;
      --d-selected: #ebebe6;
      --d-selected-hover: #efefeb;
      --d-hover: #f3f3f0;
      --primary-rgb: 38, 37, 30;
      --primary-low-rgb: 236, 235, 230;
      --primary-very-low-rgb: 249, 249, 248;
      --secondary-rgb: 247, 247, 244;
      --header_background-rgb: 247, 247, 244;
      --tertiary-rgb: 59, 58, 51;
      --primary-very-low: rgb(97.7058823529%, 97.6294117647%, 97.0941176471%);
      --primary-low: rgb(92.3529411765%, 92.0980392157%, 90.3137254902%);
      --primary-low-mid: rgb(77.0588235294%, 76.2941176471%, 70.9411764706%);
      --primary-medium: rgb(61.7647058824%, 60.4901960784%, 51.568627451%);
      --primary-high: rgb(43.9607843137%, 42.8039215686%, 34.7058823529%);
      --primary-very-high: rgb(29.431372549%, 28.6568627451%, 23.2352941176%);
      --primary-50: rgb(97.7058823529%, 97.6294117647%, 97.0941176471%);
      --primary-100: rgb(95.4117647059%, 95.2588235294%, 94.1882352941%);
      --primary-200: rgb(92.3529411765%, 92.0980392157%, 90.3137254902%);
      --primary-300: rgb(84.7058823529%, 84.1960784314%, 80.6274509804%);
      --primary-400: rgb(77.0588235294%, 76.2941176471%, 70.9411764706%);
      --primary-500: rgb(69.4117647059%, 68.3921568627%, 61.2549019608%);
      --primary-600: rgb(61.7647058824%, 60.4901960784%, 51.568627451%);
      --primary-700: rgb(51.7098039216%, 50.3490196078%, 40.8235294118%);
      --primary-800: rgb(43.9607843137%, 42.8039215686%, 34.7058823529%);
      --primary-900: rgb(29.431372549%, 28.6568627451%, 23.2352941176%);
      --header_primary-low: rgb(93.1292050185%, 93.1091392032%, 91.9087189038%);
      --header_primary-low-mid: rgb(83.0643872306%, 82.9856182794%, 81.7042612901%);
      --header_primary-medium: rgb(74.0338254103%, 73.894882581%, 72.5140350201%);
      --header_primary-high: rgb(66.4604654216%, 66.2633706847%, 64.7712088535%);
      --header_primary-very-high: rgb(54.7568109275%, 54.4488303359%, 52.7068160515%);
      --secondary-low: rgb(33.4427244582%, 33.4427244582%, 24.3219814241%);
      --secondary-medium: rgb(55.737874097%, 55.737874097%, 40.5366357069%);
      --secondary-high: rgb(68.4871001032%, 68.4871001032%, 56.6697626419%);
      --secondary-very-high: rgb(91.1876160991%, 91.1876160991%, 87.8829721362%);
      --tertiary-very-low: rgb(92.7272727273%, 92.5846702317%, 91.5864527629%);
      --tertiary-low: rgb(89.0909090909%, 88.8770053476%, 87.3796791444%);
      --tertiary-medium: rgb(63.6363636364%, 62.9233511586%, 57.9322638146%);
      --tertiary-high: rgb(39.9643493761%, 39.2869875223%, 34.5454545455%);
      --tertiary-hover: rgb(17.3529411765%, 17.0588235294%, 15%);
      --tertiary-25: rgb(94.9090909091%, 94.8092691622%, 94.110516934%);
      --tertiary-50: rgb(92.7272727273%, 92.5846702317%, 91.5864527629%);
      --tertiary-100: rgb(91.2727272727%, 91.1016042781%, 89.9037433155%);
      --tertiary-200: rgb(90.5454545455%, 90.3600713012%, 89.0623885918%);
      --tertiary-300: rgb(89.0909090909%, 88.8770053476%, 87.3796791444%);
      --tertiary-400: rgb(81.0909090909%, 80.7201426025%, 78.1247771836%);
      --tertiary-500: rgb(73.0909090909%, 72.5632798574%, 68.8698752228%);
      --tertiary-600: rgb(63.6363636364%, 62.9233511586%, 57.9322638146%);
      --tertiary-700: rgb(56.3636363636%, 55.5080213904%, 49.5187165775%);
      --tertiary-800: rgb(48.3778966132%, 47.5579322638%, 41.8181818182%);
      --tertiary-900: rgb(39.9643493761%, 39.2869875223%, 34.5454545455%);
      --danger-low: rgb(100%, 93.1622861911%, 89.2156862745%);
      --danger-low-mid: rgba(100%, 65.8114309554%, 46.0784313725%, 0.7);
      --danger-medium: rgb(100%, 52.1360033375%, 24.5098039216%);
      --danger-hover: rgb(73.7254901961%, 26.9803921569%, 0%);
      --love-low: rgb(98.0588235294%, 94.1176470588%, 98.1176470588%);
      --blend-primary-secondary-5: rgb(94.4689115016%, 94.4658591186%, 93.3005379851%);
      --primary-med-or-secondary-med: rgb(61.7647058824%, 60.4901960784%, 51.568627451%);
      --primary-med-or-secondary-high: rgb(61.7647058824%, 60.4901960784%, 51.568627451%);
      --primary-high-or-secondary-low: rgb(43.9607843137%, 42.8039215686%, 34.7058823529%);
      --primary-low-mid-or-secondary-high: rgb(77.0588235294%, 76.2941176471%, 70.9411764706%);
      --primary-low-mid-or-secondary-low: rgb(77.0588235294%, 76.2941176471%, 70.9411764706%);
      --primary-or-primary-low-mid: #26251e;
      --tertiary-or-tertiary-low: #3b3a33;
      --tertiary-low-or-tertiary-high: rgb(89.0909090909%, 88.8770053476%, 87.3796791444%);
      --tertiary-med-or-tertiary: rgb(63.6363636364%, 62.9233511586%, 57.9322638146%);
      --secondary-or-primary: #f7f7f4;
      --tertiary-or-white: #3b3a33;
      --hljs-bg: rgb(95.4117647059%, 95.2588235294%, 94.1882352941%);
      --inline-code-bg: rgb(95.4117647059%, 95.2588235294%, 94.1882352941%);
      --hljs-comment: rgb(69.4117647059%, 68.3921568627%, 61.2549019608%);
      --topic-timeline-border-color: rgb(89.0909090909%, 88.8770053476%, 87.3796791444%);
      --topic-timeline-handle-color: var(--tertiary);
      --chat-skeleton-animation-rgb: 249, 249, 248;
      --calendar-normal: rgb(78.2727272727%, 77.8467023173%, 74.8645276292%);
      --calendar-close-to-working-hours: rgb(66.568627451%, 66.568627451%, 66.568627451%);
      --calendar-in-working-hours: #9d9d9d;

      --base-font-size: 93.75%;

      --d-sidebar-background: #f0efea;
      --d-sidebar-footer-fade: #f0efea;
      --d-sidebar-link-color: var(--primary);
      --d-sidebar-highlight-color: var(--primary);
      --d-sidebar-highlight-background: color-mix(in oklab, #ebeae5 70%, transparent);
      --d-sidebar-link-icon-color: #7a7974;
      --d-sidebar-header-color: #7a7974;
      --d-sidebar-header-icon-color: #7a7974;
      --d-sidebar-active-background: transparent;
      --d-sidebar-active-color: #eb5600;
      --d-sidebar-active-suffix-color: #eb5600;
      --d-sidebar-active-font-weight: 500;
      --d-sidebar-header-font-weight: 500;

      --d-nav-color--active: #eb5600;
      --d-nav-underline-height: 2px;

      --d-button-primary-bg-color: var(--primary);
      --d-button-primary-text-color: var(--secondary);
      --d-button-primary-icon-color: var(--secondary);
      --d-button-default-bg-color: transparent;
      --d-button-default-bg-color--hover: transparent;
      --d-button-default-border-color: var(--primary-300);
      --d-button-default-text-color: var(--primary);
      --d-button-default-icon-color: var(--primary);
    }

    h1 {
      letter-spacing: -0.025em;
      line-height: 1.15;
    }

    h2 {
      letter-spacing: -0.02em;
      line-height: 1.2;
    }

    h3 {
      letter-spacing: -0.015em;
      line-height: 1.25;
    }

    .d-header .header-buttons .btn {
      background: transparent;
      color: var(--primary);
      border: 1px solid var(--primary-low);
      border-radius: 999px;
      box-shadow: none;

      .d-icon {
        color: var(--primary-medium);
      }

      &:hover,
      &:focus-visible {
        background: var(--primary-very-low);
        color: var(--primary);
      }
    }
  }
SCSS

# Whether Chat and Channels are hidden from the left sidebar. A real theme-component setting
# (Admin > Customize > Themes > nvs-cursor-look > Settings), toggleable by an admin without
# re-running this script. A component boolean setting compiles to an *unquoted string* SCSS
# variable (Theme#to_scss_variable), not a real boolean -- hence `== "true"` below, not a bare
# `@if`.
HIDE_CHAT_SETTING_NAME = "hide_channels_and_chat_from_sidebar"
SETTINGS_YAML = <<~YAML
  #{HIDE_CHAT_SETTING_NAME}:
    default: true
    client: true
YAML

# Hides chat's own sections (channels, DMs, threads, ...) from the left sidebar. Not screen-size
# dependent: on every width, including the mobile app, the header's own chat icon still opens
# chat. Independent of DESKTOP_ONLY/MEDIA above -- this is visibility, not colour scheme. Gated
# on the setting above so switching it off fully restores stock Discourse behaviour.
#
# An earlier version of this also moved chat into a custom right-hand rail (reusing
# frontend/discourse/app/components/sidebar/api-section.gjs so it would inherit the sidebar's
# own styling). Dropped: the experience wasn't good enough to ship. This is CSS-only again.
HIDE_CHAT_CSS = <<~SCSS
  @if $#{HIDE_CHAT_SETTING_NAME} == "true" {
    .sidebar-section[data-section-name^="chat-"] {
      display: none !important;
    }
  }
SCSS

# `default` and `navodians` are two multisite connections onto one database, and
# navodians.com is served by `default`. Everything cached about themes and theme settings is
# kept per connection, and the web workers only hear about a change through a message on the
# connection it was made on. So a change made through one connection is stored correctly but
# the site served through the other keeps its old theme *and* its old theme settings (banner,
# search placement) until that connection is told too. Clearing the theme cache alone fixes the
# colours but not the settings.
SHARED_DATABASE_CONNECTIONS = { "navodians" => %w[default], "default" => %w[navodians] }.freeze

def expire_theme_caches(site)
  ([site] + SHARED_DATABASE_CONNECTIONS.fetch(site, [])).each do |name|
    next if !RailsMultisite::ConnectionManagement.has_db?(name)
    RailsMultisite::ConnectionManagement.with_connection(name) do
      Theme.expire_site_cache!
      Theme.expire_site_setting_cache!
      SiteSetting.refresh!
      SiteSetting.notify_changed!
    end
    puts "[#{site}] refreshed theme caches and settings for connection #{name}"
  end
end

THEME_SETTINGS = { "search_experience" => "search_field", "enable_welcome_banner" => false }.freeze

def report(site)
  foundation = Theme.find(FOUNDATION_ID)
  tss = ThemeSiteSetting.where(theme_id: FOUNDATION_ID).pluck(:name, :value).to_h
  fonts =
    %w[base_font heading_font].to_h do |n|
      [
        n,
        DB.query_single("SELECT value FROM site_settings WHERE name = :n", n: n).first ||
          "(default inter)",
      ]
    end
  personal =
    DB.query_single(
      "SELECT count(*) FROM user_options WHERE theme_ids IS NOT NULL AND array_length(theme_ids, 1) > 0",
    ).first
  comp = Theme.find_by(name: COMPONENT_NAME, component: true)
  hide_chat_setting = comp&.settings&.dig(HIDE_CHAT_SETTING_NAME.to_sym)&.value
  puts "[#{site}] default theme: #{Theme.find_default&.name.inspect}, foundation palette: " \
         "#{foundation.color_scheme&.name.inspect}, components: #{foundation.child_themes.pluck(:name)}, " \
         "theme settings: #{tss}, fonts: #{fonts}, users with personal theme: #{personal}, " \
         "anonymous search: #{SiteSetting.allow_anonymous_search}, " \
         "#{HIDE_CHAT_SETTING_NAME}: #{hide_chat_setting.inspect}"
end

SITES.each do |site|
  RailsMultisite::ConnectionManagement.with_connection(site) do
    puts "== #{site} =="
    report(site)
    foundation = Theme.find(FOUNDATION_ID)

    if ROLLBACK
      foundation.update!(color_scheme_id: nil)
      comp = Theme.find_by(name: COMPONENT_NAME, component: true)
      foundation.child_themes.delete(comp) if comp && foundation.child_themes.exists?(id: comp.id)
      ThemeSiteSetting.where(theme_id: FOUNDATION_ID, name: THEME_SETTINGS.keys).destroy_all
      expire_theme_caches(site)
      puts "[#{site}] rolled back:"
      report(site)
      next
    end

    next puts("[#{site}] dry run, nothing changed (APPLY=1 to apply)") if !APPLY

    foundation.update!(color_scheme_id: nil)
    ColorScheme.where(name: OLD_SCHEME_NAME).destroy_all

    comp = Theme.find_by(name: COMPONENT_NAME, component: true)
    comp ||= Theme.create!(name: COMPONENT_NAME, user_id: Discourse.system_user.id, component: true)
    # Cleanup from the abandoned right-rail version of this feature: it added an extra_js field
    # that nothing here sets anymore, so it has to be removed explicitly or it lingers.
    comp
      .theme_fields
      .where(
        target_id: Theme.targets[:extra_js],
        name: "discourse/api-initializers/nvs-chat-rail.gjs",
      )
      .destroy_all
    comp.set_field(target: :settings, name: "yaml", value: SETTINGS_YAML, type: :yaml)
    comp.set_field(target: :common, name: "scss", value: CSS + HIDE_CHAT_CSS, type: :scss)
    comp.save!
    foundation.add_relative_theme!(:child, comp) if !foundation.child_themes.exists?(id: comp.id)

    THEME_SETTINGS.each do |name, value|
      Themes::ThemeSiteSettingManager.call(
        params: {
          theme_id: FOUNDATION_ID,
          name: name,
          value: value,
        },
        guardian: Discourse.system_user.guardian,
      ) { |_| }
    end

    expire_theme_caches(site)

    puts "[#{site}] applied:"
    report(site)
  end
end
