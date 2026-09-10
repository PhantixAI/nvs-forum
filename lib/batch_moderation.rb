# frozen_string_literal: true

# Explicit namespace file for lib/batch_moderation/ -- without this, Zeitwerk
# treats the directory as an *implicit* namespace, and since every sibling
# file (group_sync.rb, guardian_extension.rb, moderator.rb, notifier.rb)
# reopens `module BatchModeration` itself, whichever one gets autoloaded
# first can "shadow" Zeitwerk's own namespace-module setup on a dev-mode
# reload, leaving sibling constants (e.g. BatchModeration::GroupSync as seen
# from BatchModeration::GuardianExtension) unresolvable until a full
# restart. An explicit file here is Zeitwerk's documented fix.
module BatchModeration
end
