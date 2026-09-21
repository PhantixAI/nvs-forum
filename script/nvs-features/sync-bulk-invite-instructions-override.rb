# frozen_string_literal: true

# All three sites have a `TranslationOverride` row (Admin > Customize > Text) for
# `js.user.invited.bulk_invite.instructions` that was set at some point independently of
# `config/locales/client.en.yml` -- and since a TranslationOverride always wins over the YAML
# default (see TranslationOverride.upsert!/I18n's override lookup), editing the YAML alone (this
# session's fix documenting the `locale`/`name`/`keywords`/`skip_personalization` CSV columns) had
# no visible effect: the Bulk Invite modal kept rendering the override's older, incomplete text.
# This makes the DB override match whatever the YAML default currently says, so it stops masking
# future YAML edits to this key. Safe to re-run any time the YAML text changes again.
#
# Run inside the app (local: bin/rails runner script/nvs-features/sync-bulk-invite-instructions-override.rb;
# production: copy it into the container, then as the app user
# `cd /var/www/discourse && RAILS_ENV=production bundle exec rails runner /tmp/sync-bulk-invite-instructions-override.rb`).
#
#   (default)  report current state only, change nothing
#   APPLY=1    apply (idempotent, safe to re-run)
#   SITES=a,b,c  which multisite databases (default: nitians,iitians,navodians)

SITES = ENV.fetch("SITES", "nitians,iitians,navodians").split(",").map(&:strip)
APPLY = ENV["APPLY"] == "1"
KEY = "js.user.invited.bulk_invite.instructions"

def report(site)
  default_text = I18n.overrides_disabled { I18n.t(KEY, locale: :en) }
  override = TranslationOverride.find_by(locale: "en", translation_key: KEY)
  in_sync = override.nil? || override.value == default_text
  puts "[#{site}] override present=#{!!override} in_sync_with_yaml_default=#{in_sync}"
  [default_text, override]
end

SITES.each do |site|
  next unless RailsMultisite::ConnectionManagement.has_db?(site)
  RailsMultisite::ConnectionManagement.with_connection(site) do
    puts "== #{site} =="
    default_text, override = report(site)

    if !APPLY
      puts "[#{site}] dry run, nothing changed (APPLY=1 to apply)"
      next
    end

    if override.nil? || override.value != default_text
      TranslationOverride.upsert!("en", KEY, default_text)
      puts "[#{site}] synced override to current YAML default"
    else
      puts "[#{site}] already in sync, nothing to do"
    end
  end
end
