# frozen_string_literal: true

module BatchModeration
  module GroupSync
    CUSTOM_FIELD_FLAG = "batch_moderation_group"
    NAME_PREFIX = "bm-"
    FULL_NAME_MAX_LENGTH = 100
    STAFF_TYPE_SUFFIX = "Staff"

    # `notify:` is set to `false` by the one-time `batch_moderation:resync_cohorts`
    # rake task (see lib/tasks/batch_moderation.rake) -- re-keying every
    # existing user under a new cohort-key algorithm would otherwise fire a
    # leave+join (and possibly a status-change) notification, to every staff
    # member and cohort owner, for every single user on the site.
    def self.sync(user, notify: true)
      return unless SiteSetting.enable_batch_moderation

      key = cohort_key_for(user)
      desired_group = find_or_create_group(key) if key

      current_batch_group_ids = batch_group_ids_for(user)
      stale_ids = current_batch_group_ids - [desired_group&.id].compact

      Group
        .where(id: stale_ids)
        .find_each do |group|
          was_owner = group.group_users.where(user_id: user.id, owner: true).exists?
          group.remove(user)
          next unless notify
          Notifier.notify_cohort_change(user: user, group: group, joined: false)
          if was_owner
            Notifier.notify_moderator_status_change(
              actor: nil,
              user: user,
              group: group,
              granted: false,
            )
          end
        end

      if desired_group && !current_batch_group_ids.include?(desired_group.id)
        desired_group.add(user)
        Notifier.notify_cohort_change(user: user, group: desired_group, joined: true) if notify
        auto_promote_if_understaffed(desired_group, user, notify: notify)
      end
    end

    def self.batch_group?(group)
      return false unless group
      GroupCustomField.exists?(group_id: group.id, name: CUSTOM_FIELD_FLAG, value: "t")
    end

    def self.owned_batch_groups(user)
      return Group.none unless user && SiteSetting.enable_batch_moderation

      owned_group_ids = GroupUser.where(user_id: user.id, owner: true).select(:group_id)
      batch_group_ids =
        GroupCustomField.where(
          group_id: owned_group_ids,
          name: CUSTOM_FIELD_FLAG,
          value: "t",
        ).select(:group_id)

      Group.where(id: batch_group_ids)
    end

    # Batched form of `owned_batch_groups(user).exists?` for a list of user
    # ids, so a paginated listing (e.g. the users directory, the admin users
    # list) can compute batch-moderator status for a whole page in 2 queries
    # instead of one `owned_batch_groups` query per row.
    def self.batch_moderator_user_ids(user_ids)
      return Set.new if user_ids.blank?

      owner_pairs = GroupUser.where(user_id: user_ids, owner: true).pluck(:user_id, :group_id)
      return Set.new if owner_pairs.empty?

      batch_group_ids =
        GroupCustomField
          .where(group_id: owner_pairs.map(&:last), name: CUSTOM_FIELD_FLAG, value: "t")
          .pluck(:group_id)
          .to_set

      owner_pairs
        .filter_map { |user_id, group_id| user_id if batch_group_ids.include?(group_id) }
        .to_set
    end

    # All user ids who currently own at least one batch group -- returned as
    # an unmaterialized relation (not a Set, unlike `batch_moderator_user_ids`
    # above) so it composes into a `WHERE id IN (...)` subquery, for filtering
    # a not-yet-paginated query (e.g. the admin users list's "Batch Moderator
    # Only" filter) rather than checking a page of already-known ids.
    def self.all_batch_moderator_user_ids
      batch_group_ids =
        GroupCustomField.where(name: CUSTOM_FIELD_FLAG, value: "t").select(:group_id)
      GroupUser.where(group_id: batch_group_ids, owner: true).select(:user_id)
    end

    # Batched form of `staff_type?(user)` for a list of user ids -- one query
    # instead of one `user.custom_fields` lookup per row. Mirrors
    # `batch_moderator_user_ids` above.
    def self.staff_type_user_ids(user_ids)
      return Set.new if user_ids.blank?

      type_field = find_member_type_field
      return Set.new unless type_field

      UserCustomField
        .where(
          user_id: user_ids,
          name: "#{User::USER_FIELD_PREFIX}#{type_field.id}",
          value: SiteSetting.batch_moderation_staff_type_values.split("|"),
        )
        .pluck(:user_id)
        .to_set
    end

    # All user ids currently classified Staff-type by `staff_type?` --
    # returned as an unmaterialized relation (not a Set), so it composes into
    # a `WHERE id IN (...)` subquery for filtering a not-yet-paginated query.
    # Mirrors `all_batch_moderator_user_ids` above.
    def self.all_staff_type_user_ids
      type_field = find_member_type_field
      return UserCustomField.none.select(:user_id) unless type_field

      UserCustomField.where(
        name: "#{User::USER_FIELD_PREFIX}#{type_field.id}",
        value: SiteSetting.batch_moderation_staff_type_values.split("|"),
      ).select(:user_id)
    end

    # The single batch group a user currently belongs to (a user is only ever
    # a member of one batch group at a time -- `sync` enforces that). Returns
    # `nil` if the user isn't in one.
    def self.batch_group_for(user)
      Group.where(id: batch_group_ids_for(user)).order(:id).first
    end

    # Resolves this site's institution field (College, Vidyalaya, ...) --
    # first one found among `batch_moderation_institution_field_names` that
    # exists as a UserField on this site.
    def self.find_institution_field
      find_first_existing_field(SiteSetting.batch_moderation_institution_field_names)
    end

    # Resolves this site's additional Student-only fields (Branch, ...) that
    # exist as UserFields here -- unlike the institution/type fields, more
    # than one of these can apply at once (unlike the old single-field
    # first-match scheme), since a site could plausibly want more than one
    # extra qualifier for its student cohorts.
    def self.find_student_only_fields
      SiteSetting
        .batch_moderation_secondary_field_names
        .split("|")
        .filter_map { |name| UserField.find_by(name: name) }
    end

    # Resolves the field that distinguishes Student from Staff-type members
    # (e.g. "I am"). `nil` on a site that doesn't have this field configured
    # -- everyone is then treated as Student, same as before this field
    # existed.
    def self.find_member_type_field
      UserField.find_by(name: SiteSetting.batch_moderation_member_type_field_name)
    end

    # Computes the ordered set of (field, value) cohort-key components for a
    # user, or `nil` if their cohort isn't complete (missing a required
    # field's value). Public so specs can exercise the key logic directly
    # without going through the full `sync` side effects.
    def self.cohort_key_for(user)
      institution_field = find_institution_field
      return nil unless institution_field

      institution_value = field_value(user, institution_field)
      return nil if institution_value.blank?

      components = [[institution_field, institution_value]]

      unless staff_type?(user)
        batch_field = UserField.find_by(name: SiteSetting.batch_moderation_batch_field_name)
        return nil unless batch_field

        batch_value = field_value(user, batch_field)
        return nil if batch_value.blank?

        components << [batch_field, batch_value]

        find_student_only_fields.each do |field|
          value = field_value(user, field)
          components << [field, value] if value.present?
        end
      end

      components
    end

    def self.staff_type?(user)
      type_field = find_member_type_field
      return false unless type_field

      value = field_value(user, type_field)
      return false if value.blank?

      SiteSetting.batch_moderation_staff_type_values.split("|").include?(value)
    end

    def self.field_value(user, field)
      user.custom_fields["#{User::USER_FIELD_PREFIX}#{field.id}"]
    end
    private_class_method :field_value

    def self.find_first_existing_field(pipe_delimited_names)
      pipe_delimited_names
        .split("|")
        .each do |name|
          field = UserField.find_by(name: name)
          return field if field
        end
      nil
    end
    private_class_method :find_first_existing_field

    def self.auto_promote_if_understaffed(group, user, notify: true)
      return if SiteSetting.batch_moderation_auto_promote_count <= 0
      if group.group_users.where(owner: true).count >=
           SiteSetting.batch_moderation_auto_promote_count
        return
      end

      group.add_owner(user)
      return unless notify
      Notifier.notify_moderator_status_change(actor: nil, user: user, group: group, granted: true)
    end
    private_class_method :auto_promote_if_understaffed

    def self.find_or_create_group(key)
      name = deterministic_name(key)
      Group.find_by(name: name) || create_group(name, key)
    rescue ActiveRecord::RecordNotUnique
      Group.find_by(name: name)
    end
    private_class_method :find_or_create_group

    def self.deterministic_name(key)
      digest = Digest::SHA1.hexdigest(key.map { |_field, value| value }.join(" "))[0, 12]
      "#{NAME_PREFIX}#{digest}"
    end
    private_class_method :deterministic_name

    def self.create_group(name, key)
      values = key.map { |_field, value| value }
      values << STAFF_TYPE_SUFFIX if key.length == 1
      full_name = values.join(" · ")

      group =
        Group.new(
          name: name,
          full_name: full_name.truncate(FULL_NAME_MAX_LENGTH),
          automatic: false,
          visibility_level: Group.visibility_levels[:logged_on_users],
          members_visibility_level: Group.visibility_levels[:logged_on_users],
          mentionable_level: Group::ALIAS_LEVELS[:nobody],
          messageable_level: Group::ALIAS_LEVELS[:nobody],
        )
      group.custom_fields[CUSTOM_FIELD_FLAG] = true
      group.save!
      group
    end
    private_class_method :create_group

    def self.batch_group_ids_for(user)
      member_group_ids = GroupUser.where(user_id: user.id).select(:group_id)
      GroupCustomField.where(group_id: member_group_ids, name: CUSTOM_FIELD_FLAG, value: "t").pluck(
        :group_id,
      )
    end
  end
end
