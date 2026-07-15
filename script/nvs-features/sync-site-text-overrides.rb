# frozen_string_literal: true

# A `TranslationOverride` row (Admin > Customize > Text) always wins over the YAML default in
# config/locales/client.en.yml (see TranslationOverride.upsert!/I18n's override lookup) -- so a key
# that already has an override silently keeps showing its old value after a YAML edit, no matter
# how the new deploy happened. Separately, a `js.*` key with NO override at all is served from the
# shared, cross-site MAIN_BUNDLE (app/controllers/extra_locales_controller.rb's SHARED_BUNDLES),
# whose CDN cache key does not vary per site -- so it can keep serving stale content behind a CDN
# even though every site-specific bundle (OVERRIDES_BUNDLE) gets its own cache key via the
# `?__ws=<hostname>` query param. Setting an explicit override per site sidesteps that shared-cache
# path entirely going forward, for this key and any other `js.*` text, not just the bulk-invite one
# this script originally existed for.
#
# This makes each site's override match whatever the YAML default currently says for every key
# listed, so it stops masking (or being vulnerable to stale-CDN-behind) future YAML edits to those
# keys. Safe to re-run any time the YAML text changes again.
#
# Run inside the app (local: bin/rails runner script/nvs-features/sync-site-text-overrides.rb;
# production: copy it into the container, then as the app user
# `cd /var/www/discourse && RAILS_ENV=production bundle exec rails runner /tmp/sync-site-text-overrides.rb`).
#
#   (default)  report current state only, change nothing
#   APPLY=1    apply (idempotent, safe to re-run)
#   SITES=a,b,c  which multisite databases (default: nitians,iitians,navodians)
#   KEYS=a,b,c   which translation keys to sync (default: just the bulk-invite instructions key,
#                for backward compatibility with how this script used to be invoked)

SITES = ENV.fetch("SITES", "nitians,iitians,navodians").split(",").map(&:strip)
KEYS = ENV.fetch("KEYS", "js.user.invited.bulk_invite.instructions").split(",").map(&:strip)
APPLY = ENV["APPLY"] == "1"

def report(site, key)
  default_text = I18n.overrides_disabled { I18n.t(key, locale: :en) }
  override = TranslationOverride.find_by(locale: "en", translation_key: key)
  in_sync = override.nil? || override.value == default_text
  puts "[#{site}] #{key}: override present=#{!!override} in_sync_with_yaml_default=#{in_sync}"
  [default_text, override]
end

SITES.each do |site|
  next unless RailsMultisite::ConnectionManagement.has_db?(site)
  RailsMultisite::ConnectionManagement.with_connection(site) do
    puts "== #{site} =="

    KEYS.each do |key|
      default_text, override = report(site, key)

      if !APPLY
        puts "[#{site}] #{key}: dry run, nothing changed (APPLY=1 to apply)"
        next
      end

      if override.nil? || override.value != default_text
        TranslationOverride.upsert!("en", key, default_text)
        puts "[#{site}] #{key}: synced override to current YAML default"
      else
        puts "[#{site}] #{key}: already in sync, nothing to do"
      end
    end
  end
end
