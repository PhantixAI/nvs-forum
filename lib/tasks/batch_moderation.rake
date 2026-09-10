# frozen_string_literal: true

desc "Re-sync every user's batch-moderation cohort group under the current cohort-key logic, and clean up now-orphaned cohort groups"
task "batch_moderation:resync_cohorts" => :environment do
  RailsMultisite::ConnectionManagement.each_connection do |db|
    next unless SiteSetting.enable_batch_moderation

    puts "[#{db}] resyncing cohorts..."
    count = 0
    User.find_each do |user|
      # Re-keying every existing user under a new cohort-key algorithm would
      # otherwise fire a leave+join (and possibly grant/revoke) notification
      # -- one in-app Notification plus one enqueued email job per recipient
      # -- to every staff member and cohort owner, for every single user on
      # the site. Suppressed here; this is a one-time backfill, not a real
      # moderation event.
      BatchModeration::GroupSync.sync(user, notify: false)
      count += 1
    end
    puts "[#{db}] resynced #{count} users"

    orphaned =
      Group
        .joins(:_custom_fields)
        .where(
          group_custom_fields: {
            name: BatchModeration::GroupSync::CUSTOM_FIELD_FLAG,
            value: "t",
          },
        )
        .where
        .missing(:group_users)
    orphaned_count = orphaned.count
    orphaned.find_each(&:destroy!)
    puts "[#{db}] destroyed #{orphaned_count} orphaned cohort group(s)"
  end
end

# One-time migration (see custom-feature.md for the full rollout plan): existing
# users predate the Student/Staff member-type field on some sites, and predate it
# being filled in on others, so `BatchModeration::GroupSync.staff_type?` would
# treat everyone as Student. This backfills it -- run before resync_cohorts, once
# per site, then run resync_cohorts to actually re-key everyone's cohort group.
#
# Deliberately reads no site names: the "Student-only" fields
# (`GroupSync.find_student_only_fields`) already resolve to exactly [Branch] on a
# site that has Branch configured as a secondary field and to [] on a site that
# doesn't, which is what turns "has Batch AND Branch" vs "has Batch" into a single
# site-agnostic rule.
desc "Backfill each user's Student/Staff member-type field (creating the field/options if missing) so the cohort-key algorithm can classify them correctly -- run before batch_moderation:resync_cohorts. Defaults to a dry run; pass DRY_RUN=0 to write."
task "batch_moderation:backfill_member_type" => :environment do
  dry_run = ENV["DRY_RUN"] != "0"
  student_label = "Alumni/Student"

  RailsMultisite::ConnectionManagement.each_connection do |db|
    type_field_name = SiteSetting.batch_moderation_member_type_field_name
    staff_label = SiteSetting.batch_moderation_staff_type_values.split("|").first

    if staff_label.blank?
      puts "[#{db}] skipped -- batch_moderation_staff_type_values is not configured"
      next
    end

    field = UserField.find_by(name: type_field_name)

    if field.nil?
      if dry_run
        puts "[#{db}] #{type_field_name.inspect} field does not exist -- would be created; re-run with DRY_RUN=0 to create it and preview per-user impact"
        next
      end

      field =
        UserField.create!(
          name: type_field_name,
          description: "Association Type",
          field_type_enum: :dropdown,
          editable: true,
          show_on_profile: true,
          show_on_signup: true,
          show_on_user_card: true,
          searchable: true,
          requirement: :for_all_users,
        )
      puts "[#{db}] created #{type_field_name.inspect} field"
    else
      puts "[#{db}] #{type_field_name.inspect} field already exists (id=#{field.id})"
    end

    [student_label, staff_label].each do |value|
      next if field.user_field_options.exists?(value: value)

      if dry_run
        puts "[#{db}] would add option #{value.inspect} to #{type_field_name.inspect}"
      else
        field.user_field_options.create!(value: value)
        puts "[#{db}] added option #{value.inspect} to #{type_field_name.inspect}"
      end
    end

    batch_field = UserField.find_by(name: SiteSetting.batch_moderation_batch_field_name)
    if batch_field.nil?
      puts "[#{db}] skipped user backfill -- Batch field #{SiteSetting.batch_moderation_batch_field_name.inspect} not found"
      next
    end

    student_only_fields = BatchModeration::GroupSync.find_student_only_fields
    value_present = ->(user, f) { user.custom_fields["#{User::USER_FIELD_PREFIX}#{f.id}"].present? }
    key = "#{User::USER_FIELD_PREFIX}#{field.id}"

    skipped = 0
    student_count = 0
    staff_count = 0

    User.real.find_each do |user|
      if user.custom_fields[key].present?
        skipped += 1
        next
      end

      is_student =
        value_present.call(user, batch_field) &&
          student_only_fields.all? { |f| value_present.call(user, f) }
      value = is_student ? student_label : staff_label
      is_student ? (student_count += 1) : (staff_count += 1)

      next if dry_run

      user.custom_fields[key] = value
      user.save_custom_fields
    end

    verb = dry_run ? "would set" : "set"
    puts "[#{db}] #{verb} #{student_count} user(s) to #{student_label.inspect}, #{staff_count} to #{staff_label.inspect}, skipped #{skipped} already-set user(s)"
  end
end

# One-time migration companion to backfill_member_type/resync_cohorts: the old
# system granted broad Discourse Site Moderator status to many users before Batch
# Moderator existed as a narrower alternative. This retires that blanket grant.
desc "Revoke Discourse Site Moderator status from every non-admin user (the old blanket-moderator system, superseded by Batch Moderator). Defaults to a dry run; pass DRY_RUN=0 to write."
task "batch_moderation:revoke_site_moderators" => :environment do
  dry_run = ENV["DRY_RUN"] != "0"

  RailsMultisite::ConnectionManagement.each_connection do |db|
    users = User.real.where(moderator: true, admin: false)
    count = users.count

    if dry_run
      preview = users.limit(20).pluck(:username)
      preview << "..." if count > preview.length
      puts "[#{db}] would revoke Site Moderator from #{count} user(s): #{preview.join(", ")}"
      next
    end

    logger = StaffActionLogger.new(Discourse.system_user)
    users.find_each do |user|
      user.revoke_moderation!
      logger.log_revoke_moderation(user)
    end
    puts "[#{db}] revoked Site Moderator from #{count} user(s)"
  end
end
